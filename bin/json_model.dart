import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import 'build_runner.dart' as br;

// Dart file template
const tpl =
    "import 'package:json_annotation/json_annotation.dart';\n%t\npart '%s.g.dart';\n\n@JsonSerializable()\nclass %s {\n  %s();\n\n  %s\n  factory %s.fromJson(Map<String,dynamic> json) => _\$%sFromJson(json);\n  Map<String, dynamic> toJson() => _\$%sToJson(this);\n}\n";

void main(List<String> args) {
  String? src;
  String? dist;
  String? tag;
  bool nullable = false;
  bool clean = false;
  final parser = ArgParser();
  parser.addOption(
    'src',
    defaultsTo: './Jsons',
    callback: (v) => src = v,
    help: "Specify the Json directory.",
  );
  parser.addOption(
    'dist',
    defaultsTo: 'lib/models',
    callback: (v) => dist = v,
    help: "Specify the dist directory.",
  );

  parser.addOption(
    'tag',
    defaultsTo: '\$',
    callback: (v) => tag = v,
    help: "Specify the tag ",
  );

  parser.addFlag('nullable', callback: (v) => nullable = v);
  parser.addFlag('clean', callback: (v) => clean = v);

  parser.parse(args);

  if (clean) {
    br.run(['clean']);
  } else if (generateModelClass(src!, dist!, tag!, nullable: nullable)) {
    br.run(['build', '--delete-conflicting-outputs']);
  }
}

bool generateModelClass(
  String srcDir,
  String distDir,
  String tag, {
  required bool nullable,
}) {
  const metaTag = "@meta";
  if (srcDir.endsWith("/")) srcDir = srcDir.substring(0, srcDir.length - 1);
  if (distDir.endsWith("/")) distDir = distDir.substring(0, distDir.length - 1);

  final src = Directory(srcDir);
  final fileList = src.listSync(recursive: true);
  String indexFile = "";
  if (fileList.isEmpty) return false;
  if (!Directory(distDir).existsSync()) {
    Directory(distDir).createSync(recursive: true);
  }

  File file;

  fileList.forEach((f) {
    if (FileSystemEntity.isFileSync(f.path)) {
      file = File(f.path);
      final paths = path.basename(f.path).split(".");
      final String fileName = paths.first;
      if (paths.last.toLowerCase() != "json" || fileName.startsWith("_")) return;

      final dartFilePath =
          f.path.replaceFirst(srcDir, distDir).replaceFirst(RegExp('.json', caseSensitive: false), ".dart");

      final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;

      // To ensure that import statements are not repeated,
      // we use Set to save import statements
      final importSet = Set<String>();

      //Create a case-insensitive Map for the meta data of Json file
      final meta = LinkedHashMap<String, dynamic>(
        equals: (a, b) => a.toLowerCase().trim() == b.toLowerCase().trim(),
        hashCode: (k) => k.toLowerCase().hashCode,
      );

      // Get the meta data of Json file
      if (map[metaTag] != null) {
        meta.addAll(map[metaTag] as Map<String, dynamic>);
        map.remove(metaTag);
      }

      //generated class name
      String? className = meta['className'] as String?;
      if (className == null || className.isEmpty) {
        className = snakeCaseToCamelCase(fileName);
      }

      //set ignore
      final bool ignore = (meta['ignore'] ?? false) as bool;
      if (ignore) {
        print('skip: ${f.path}');
        indexFile = exportIndexFile(dartFilePath, distDir, indexFile);
        return;
      }

      //handle imports
      final List imports = (meta['import'] ?? []) as List;
      imports.forEach((e) => importSet.add("import '$e'"));

      //set nullable
      final bool _nullable = (meta['nullable'] ?? nullable) as bool;

      // comments for Json fields
      final comments = meta['comments'] ?? {};

      // Handle fields in Json file
      final StringBuffer fields = StringBuffer();
      map.forEach((key, v) {
        key = key.trim();
        if (key.startsWith("_")) return;
        if (key.startsWith("@")) {
          if (comments[v] != null) {
            _writeComments(comments[v], fields);
          }
          fields.write(key);
          fields.write(" ");
          fields.write(v);
          fields.writeln(";");
        } else {
          final bool optionalField = key.endsWith('?');
          final bool notNull = key.endsWith('!');
          if (optionalField || notNull) {
            key = key.substring(0, key.length - 1);
          }
          final bool shouldAppendOptionalFlag = !notNull && (optionalField || _nullable);

          if (comments[key] != null) {
            _writeComments(comments[key], fields);
          }
          if (!shouldAppendOptionalFlag) {
            fields.write('late ');
          }
          var dataType = getDataType(v, importSet, fileName, tag);
          fields.write(dataType);
          if (shouldAppendOptionalFlag && dataType != 'dynamic') {
            fields.write('?');
          }
          fields.write(" ");
          fields.write(key);
          //new line
          fields.writeln(";");
        }
        //indent
        fields.write("  ");
      });

      var dist =
          replaceTemplate(tpl, [fileName, className, className, fields.toString(), className, className, className]);
      // Insert the imports at the head of dart file.
      var _import = importSet.join(";\r\n");
      _import += _import.isEmpty ? "" : ";";
      dist = dist.replaceFirst("%t", _import);
      //Create dart file
      File(dartFilePath)
        ..createSync(recursive: true)
        ..writeAsStringSync(dist);
      indexFile = exportIndexFile(dartFilePath, distDir, indexFile);
      print('done: ${f.path} -> $dartFilePath');
    }
  });
  if (indexFile.isNotEmpty) {
    final p = path.join(distDir, "index.dart");
    File(p).writeAsStringSync(indexFile);
    print('create index file: $p');
  }
  return indexFile.isNotEmpty;
}

_writeComments(dynamic comments, StringBuffer sb) {
  final arr = '$comments'.replaceAll('\r', '').split('\n');
  arr.forEach((element) {
    sb.writeln('// $element');
    sb.write('  ');
  });
}

String exportIndexFile(String p, String distDir, String indexFile) {
  var relative = p.replaceFirst(distDir + path.separator, "");
  relative = relative.replaceAll(r'\', '/');

  indexFile += "export '$relative' ; \n";
  return indexFile;
}

String changeFirstChar(String str, [bool upper = true]) {
  return (upper ? str[0].toUpperCase() : str[0].toLowerCase()) + str.substring(1);
}

bool isBuiltInType(String type) {
  return ['int', 'num', 'string', 'double', 'map', 'list', 'dynamic'].contains(type);
}

String getDataType(v, Set<String> set, String current, String tag) {
  final isListType = v is String && v.startsWith("$tag[]");

  if (v is bool) return "bool";

  if (v is num) return "num";

  if (v is Map) return "Map<String, dynamic>";

  if (v is List) return "List";

  if (v is String && v.startsWith("@")) return v;

  if (v is String && (isListType || v.startsWith(tag))) {
    // handle other type that is not built-in
    final typeName = v.substring(isListType ? 3 : 1);
    final type = snakeCaseToCamelCase(typeName, !['bool', 'int', 'num', 'double', 'dynamic'].contains(typeName));

    if (snakeCaseToCamelCase(typeName) != snakeCaseToCamelCase(current) && !isBuiltInType(typeName)) {
      set.add('import "${camelCaseToSnakeCase(typeName)}.dart"');
    }

    return isListType ? "List<$type>" : type;
  }

  return "String";
}

String replaceTemplate(String template, List<Object> params) {
  int matchIndex = 0;
  String replace(Match m) {
    if (matchIndex < params.length) {
      switch (m[0]) {
        case "%s":
          return params[matchIndex++].toString();
      }
    } else {
      throw Exception("Missing parameter for string format");
    }
    throw Exception("Invalid format string: " + m[0].toString());
  }

  return template.replaceAllMapped("%s", replace);
}

String snakeCaseToCamelCase(String name, [bool upperFirstCase = true]) {
  List<String> words = name.split('_');
  String result = '';

  for (var index in words.asMap().keys) {
    result += changeFirstChar(words[index], upperFirstCase || index > 0);
  }

  return result;
}

String camelCaseToSnakeCase(String camelCaseStr) {
  return camelCaseStr
      .replaceAllMapped(
        RegExp('([a-z])([A-Z])'),
        (Match m) => '${m.group(1)}_${m.group(2)}',
      )
      .toLowerCase();
}
