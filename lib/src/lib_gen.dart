// ignore_for_file: deprecated_member_use idk what im doing

// -----------------------------------------------------------------------------
// DscriptNamespace source generator
// -----------------------------------------------------------------------------
// This generator scans for classes annotated with `@Namespace` and emits a
// LibraryBinding subclass scaffold that:
//   • Registers all *non-private* methods declared directly on the class
//     (not inherited) as `RuntimeBinding`s.
//   • Builds parameter/return-type metadata for the Dscript runtime.
//   • Aggregates permission annotations `@RequirePerm(...)` per method.
//   • Provides global pre/post middleware registration for each binding.
//
// NOTE: This generator relies on analyzer "element2" APIs which are currently
// considered internal/unstable. Expect breaking changes across analyzer
// versions. Keep the imports pinned and update alongside analyzer bumps.
// -----------------------------------------------------------------------------

import 'package:analyzer/dart/element/element2.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'package:dscript_annotations/dscript_annotations.dart';

/// Generator that targets classes annotated with [Namespace] and emits a
/// `_\$<ClassName>` abstract superclass containing Dscript binding metadata
/// and middleware hooks for all directly-declared public methods.
class DscriptNamespace extends GeneratorForAnnotation<Namespace> {
  /// Entrypoint for source_gen.
  ///
  /// * Validates the annotated element is a [ClassElement2].
  /// * Constructs the [Namespace] metadata (defaulting to class name).
  /// * Delegates code emission to [generateSuperClass].
  @override
  generateForAnnotatedElement(
    Element2 element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element is! ClassElement2) {
      throw InvalidGenerationSourceError(
        'The @Namespace annotation can only be applied to classes.',
        element: element,
      );
    }

    final name = annotation.peek('name')?.stringValue ?? '';

    final meta = Namespace(
      name.isNotEmpty
          ? name
          : buildStep.inputId.pathSegments.last.split('.').first,
    );

    return generateSuperClass(element: element, meta: meta);
  }

  /// Normalizes a Dart doc comment block into a single-line, escaped string
  /// suitable for embedding inside generated code.
  ///
  /// Removes leading `///` and joins with `\n` (escaped newline) so values can
  /// be safely included in string literals.
  String sanatizeDocComment(String? doc) {
    if (doc == null) return '';
    return doc
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^\s*///\s?'), ''))
        .join('\\n');
  }

  /// Converts a non-async [DartType] to the Dscript `$Type` DSL wrapper.
  ///
  /// Throws if the type is `Future`/`FutureOr`, because bindings must expose
  /// `FutureOr<T>` at the method level and we only encode the inner `T` here.
  String toDslType(DartType type) {
    if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
      throw ArgumentError.value(
        type,
        'type',
        'The type must not be a Future or FutureOr.',
      );
    }

    final knownType = convertKnownType(type);

    if (knownType != null) {
      final nullable = type.nullabilitySuffix == NullabilitySuffix.question;

      return '$knownType${nullable ? '.asNullable()' : ''}';
    }

    return stringToDslType(type.toString());
  }

  /// Converts the given Dart type to a known Dscript type representation.
  /// For example, it converts `int` to `PrimitiveType.INT`.
  ///
  /// Returns a string representation of the Dscript type, or null if the type
  /// is not recognized.
  String? convertKnownType(DartType type) {
    if (type is DynamicType || type.isDartCoreObject) {
      return 'const DynamicType()';
    }

    switch (type) {
      case DartType(isDartCoreObject: true):
      case DynamicType():
        return 'const DynamicType()';
      case DartType(isDartCoreBool: true):
      case DartType(isDartCoreNull: true):
      case DartType(isDartCoreInt: true):
      case DartType(isDartCoreDouble: true):
      case DartType(isDartCoreNum: true):
      case DartType(isDartCoreString: true):
        return 'PrimitiveType.${type.toString().toUpperCase().replaceAll('?', '')}';
      case ParameterizedType(isDartCoreList: true):
        return 'ListType(elementType: ${toDslType(type.typeArguments.first)})';

      case ParameterizedType(isDartCoreMap: true):
        return 'MapType(keyType: ${toDslType(type.typeArguments.first)}, valueType: ${toDslType(type.typeArguments.last)})';
      default:
        return null;
    }
  }

  /// Wraps a raw type name string as a `$Type` in the DSL.
  ///
  /// Example: `"String"` -> `"$Type.from('String')"`.
  String stringToDslType(String type) {
    return "\$Type.from('$type')";
  }

  /// Generates the abstract superclass `_\$<ClassName>` that:
  ///
  /// * Extends `LibraryBinding` with the namespace name/description.
  /// * Exposes a `bindings` set aggregating all method bindings.
  /// * Emits a `RuntimeBinding` getter and middleware lists per method.
  /// * Emits a `registerGlobalMiddlewares` helper that routes by binding shape.
  String generateSuperClass({
    required ClassElement2 element,
    required Namespace meta,
  }) {
    // Only include methods declared on the class itself (exclude inherited).
    final bindings = element.methods2
        .where(
          (method) => !method.isPrivate && method.enclosingElement2 == element,
        )
        .toList();

    final className = element.name3!;

    final bindingTypes = bindings.asMap().map(
      (index, method) => MapEntry(
        method.name3!,
        extractFutureReturnType(method.returnType).toString(),
      ),
    );

    return '''


abstract class _\$$className extends LibraryBinding {
  const _\$$className() : super(name: '${meta.name}', description: '${sanatizeDocComment(element.documentationComment)}');

  @override
  Set<RuntimeBinding> get bindings => {
    ${bindings.map((binding) => '${binding.name3}Binding').join(',\n    ')}
  };

${bindings.map((method) => generateBinding(method)).join('\n\n')}

${generateRegisterGlobalMiddlewares(meta.name, bindingTypes)}


}
''';
  }

  /// Extracts the return type of a future or future-like type.
  ///
  /// If the type is `FutureOr<T>`/`Future<T>`, it returns `T`. Otherwise, it returns the
  /// original type.
  DartType extractFutureReturnType(DartType type) {
    if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
      return (type as ParameterizedType).typeArguments.first;
    }
    return type;
  }

  /// Emits all code for a single method binding:
  ///
  /// * Validates the return type is `FutureOr<T>` and extracts `T`.
  /// * Builds positional/named parameter maps as `$Type` descriptors.
  /// * Collects `@RequirePerm(...)` annotations as *literal* strings.
  /// * Generates middleware lists and a shape-check helper for global routing.
  String generateBinding(MethodElement2 method) {
    final type = extractFutureReturnType(method.returnType);

    final name = method.name3!;
    final description = sanatizeDocComment(method.documentationComment);

    final dslReturnType = toDslType(type);

    // Positional parameters: {'paramName': $Type}
    final positionalParams = Map.fromEntries(
      method.formalParameters.where((param) => !param.isNamed).map((param) {
        return MapEntry("'${param.name3}'", toDslType(param.type));
      }),
    );

    // Named parameters: {'#paramName': $Type}
    final namedParams = Map.fromEntries(
      method.formalParameters
          .where((param) => param.isNamed)
          .map((param) => MapEntry('#${param.name3}', toDslType(param.type))),
    );

    // Collect literal permission expressions from @RequirePerm(...)
    // We intentionally keep the source literal to support expressions like
    // ScriptPermission.custom('xyz') that cannot be resolved to constants here.
    final permissions = method.metadata2.annotations
        .where(
          (a) =>
              a.element2?.enclosingElement2?.name3 == (RequirePerm).toString(),
        )
        .map((a) {
          // Extract the inner literal by stripping the annotation wrapper.
          final src = a.toSource();
          final literal = src
              .replaceFirst(RegExp(r'^@RequirePerm\('), '')
              .replaceFirst(RegExp(r'\)$'), '');
          return literal;
        })
        .toList();

    return '''
${generateGlobalMiddlewares(name: name, type: type.toString())}

${generateBindingCheck(name)}



${method.documentationComment ?? ''}
${method.toString()};


/// Binding for [$name].
RuntimeBinding<$type> get ${name}Binding => RuntimeBinding<$type>(
      name: '$name',
      description: '$description',
      function: $name,
      returnType: $dslReturnType,
      positionalParams: $positionalParams,
      namedParams: $namedParams,
      permissions: const $permissions,
      preMiddlewares: _${name}PreMiddlewares,
      postMiddlewares: _${name}PostMiddlewares,
    );



''';
  }

  /// Emits a structural equality check used to route global middlewares to the
  /// correct binding instance (avoiding name-collisions across libraries).
  String generateBindingCheck(String name) {
    final binding = '${name}Binding';

    return '''
bool _is${name}Binding(RuntimeBinding binding) {
  return binding.name == '$name' &&
      binding.description == $binding.description &&
      binding.returnType == $binding.returnType &&
      binding.positionalParams == $binding.positionalParams &&
      binding.namedParams == $binding.namedParams &&
      binding.permissions == $binding.permissions;
}
''';
  }

  /// Emits per-binding global middleware lists used by the generated getters.
  String generateGlobalMiddlewares({
    required String name,
    required String type,
  }) {
    return '''
static final List<PostBindingMiddleware<$type>> _${name}PostMiddlewares = [];
static final List<PreBindingMiddleware<$type>> _${name}PreMiddlewares = [];
''';
  }

  /// Emits the `registerGlobalMiddlewares` helper that accepts a
  /// `RuntimeBinding<T>` and a list of pre/post middlewares and forwards them
  /// to the type-specific lists for the matching binding.
  String generateRegisterGlobalMiddlewares(
    String libName,
    Map<String, String> bindings,
  ) {
    final List<String> bindingChecks = bindings.entries.map((entry) {
      final name = entry.key;
      final type = entry.value;
      return '''
if (_is${name}Binding(binding)) {
  _${name}PreMiddlewares
      .addAll(preMiddlewares as List<PreBindingMiddleware<$type>>);
  _${name}PostMiddlewares
      .addAll(postMiddlewares as List<PostBindingMiddleware<$type>>);

  return;
}
''';
    }).toList();

    return '''

/// Registers global middlewares for a [RuntimeBinding].
/// 
/// These middlewares will always run when a binding is called, regardless of the context.
/// 
/// For context aware middlewares you can call the [RuntimeBinding.addPreBindingMiddleware] and [RuntimeBinding.addPostBindingMiddleware] methods on the binding directly.
void registerGlobalMiddlewares<T>(RuntimeBinding<T> binding,
    {List<PreBindingMiddleware<T>> preMiddlewares = const [],
    List<PostBindingMiddleware<T>> postMiddlewares = const []}) {

  ${bindingChecks.join('\n')}

  // If no binding matched, throw an error.
  
    throw ArgumentError.value(binding, 'binding',
        'Binding does not match any known bindings in $libName: ${bindings.values.join(', ')}');
}
''';
  }
}
