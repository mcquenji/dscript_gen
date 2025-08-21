import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';
import 'src/lib_gen.dart';

Builder namespaceBuilder(BuilderOptions _) =>
    SharedPartBuilder([DscriptNamespace()], 'namespace');
