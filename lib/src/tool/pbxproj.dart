import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'config.dart';

/// Minimal, format-preserving edits to an Xcode project.pbxproj written by
/// Xcode (one object per line for build files and file references, tab
/// indentation, `/* Begin <isa> section */` markers).
///
/// Every object this tool adds has an ID starting with [ownPrefix] plus a
/// tag for its kind, derived from a stable key, so running a command again
/// first strips its own objects and then re-adds them.
class PbxProject {
  PbxProject(this.text);

  String text;

  static const ownPrefix = '5A55E7';

  /// A deterministic object ID: [ownPrefix] + [kind] (2 hex digits) + a hash
  /// of [key].
  static String id(String kind, String key) {
    final hash = md5.convert(utf8.encode('store_asset_packs:$kind:$key'));
    return '$ownPrefix$kind${hash.toString().substring(0, 16)}'.toUpperCase();
  }

  /// Removes every object whose ID starts with `ownPrefix + kind`, and every
  /// list entry referring to one.
  void removeOwn(String kind) {
    final prefix = '$ownPrefix$kind';
    // Single-line objects.
    text = text.replaceAll(
      RegExp(
        '^\\t\\t$prefix[0-9A-F]+ (/\\*.*?\\*/ )?= \\{.*\\};\\n',
        multiLine: true,
      ),
      '',
    );
    // Multi-line objects.
    text = text.replaceAll(
      RegExp(
        '^\\t\\t$prefix[0-9A-F]+ (/\\*.*?\\*/ )?= \\{\\n[\\s\\S]*?^\\t\\t\\};\\n',
        multiLine: true,
      ),
      '',
    );
    // References in lists.
    text = text.replaceAll(
      RegExp('^\\t+$prefix[0-9A-F]+( /\\*.*?\\*/)?,\\n', multiLine: true),
      '',
    );
    // Empty sections left behind.
    text = text.replaceAll(
      RegExp(r'\n/\* Begin (\w+) section \*/\n/\* End \1 section \*/\n'),
      '\n',
    );
  }

  /// Adds [object] (one or more lines, without trailing newline, indented with
  /// two tabs) to the section for [isa], creating the section if needed.
  void addObject(String isa, String object) {
    final begin = '/* Begin $isa section */\n';
    final at = text.indexOf(begin);
    if (at >= 0) {
      final insert = at + begin.length;
      text = '${text.substring(0, insert)}$object\n${text.substring(insert)}';
      return;
    }
    // Sections are sorted by isa; insert before the first one that sorts
    // after this one, or before the end of `objects`.
    final sections = RegExp(
      r'^/\* Begin (\w+) section \*/$',
      multiLine: true,
    ).allMatches(text);
    var insertAt = -1;
    for (final s in sections) {
      if (s[1]!.compareTo(isa) > 0) {
        insertAt = s.start;
        break;
      }
    }
    if (insertAt < 0) {
      final end = RegExp(
        r'^\t\};\n\trootObject',
        multiLine: true,
      ).firstMatch(text);
      if (end == null) {
        throw ToolException('Unrecognized project.pbxproj layout.');
      }
      insertAt = end.start;
    }
    text =
        '${text.substring(0, insertAt)}$begin$object\n/* End $isa section */\n'
        '\n${text.substring(insertAt)}';
  }

  /// The text of the object with [id], or null.
  ({int start, int end, String body})? object(String id) {
    final single = RegExp(
      '^\\t\\t$id (/\\*.*?\\*/ )?= \\{.*\\};\\n',
      multiLine: true,
    ).firstMatch(text);
    if (single != null) {
      return (start: single.start, end: single.end, body: single[0]!);
    }
    final multi = RegExp(
      '^\\t\\t$id (/\\*.*?\\*/ )?= \\{\\n[\\s\\S]*?^\\t\\t\\};\\n',
      multiLine: true,
    ).firstMatch(text);
    if (multi == null) return null;
    return (start: multi.start, end: multi.end, body: multi[0]!);
  }

  String requireObject(String id, String what) {
    final o = object(id);
    if (o == null) {
      throw ToolException('project.pbxproj: $what ($id) not found.');
    }
    return o.body;
  }

  /// IDs of objects of [isa] (multi-line objects only).
  Iterable<String> idsOf(String isa) => RegExp(
    '^\\t\\t([0-9A-F]{24}) (?:/\\*.*?\\*/ )?= \\{\\n\\t\\t\\tisa = $isa;',
    multiLine: true,
  ).allMatches(text).map((m) => m[1]!);

  /// The value of a scalar field in an object body.
  static String? field(String body, String name) {
    final m = RegExp(
      '^\\t+$name = (.*?)( /\\*.*?\\*/)?;\$',
      multiLine: true,
    ).firstMatch(body);
    return m?[1];
  }

  /// IDs listed in the list field [name] of an object body.
  static List<String> listIds(String body, String name) {
    final m = RegExp(
      '^\\t+$name = \\(\\n([\\s\\S]*?)^\\t+\\);',
      multiLine: true,
    ).firstMatch(body);
    if (m == null) return [];
    return RegExp(
      r'^\t+([0-9A-F]{24})',
      multiLine: true,
    ).allMatches(m[1]!).map((x) => x[1]!).toList();
  }

  /// Appends [entries] (e.g. `ID /* comment */`) to the list field [name] of
  /// object [id]. [after] puts them right after an existing entry instead.
  void addToList(
    String id,
    String name,
    List<String> entries, {
    String? after,
  }) {
    if (entries.isEmpty) return;
    final o = object(id);
    if (o == null) {
      throw ToolException('project.pbxproj: object $id not found.');
    }
    final list = RegExp(
      '^(\\t+)$name = \\(\\n([\\s\\S]*?)^\\t+\\);',
      multiLine: true,
    ).firstMatch(o.body);
    if (list == null) {
      throw ToolException('project.pbxproj: $id has no $name list.');
    }
    final indent = '${list[1]}\t';
    final lines = entries.map((e) => '$indent$e,\n').join();
    var insert = list.start + list[0]!.indexOf('\n') + 1 + list[2]!.length;
    if (after != null) {
      final a = RegExp(
        '^\\t+$after.*\\n',
        multiLine: true,
      ).firstMatch(list[2]!);
      if (a != null) {
        insert = list.start + list[0]!.indexOf('\n') + 1 + a.end;
      }
    }
    final body =
        '${o.body.substring(0, insert)}$lines${o.body.substring(insert)}';
    text = text.replaceRange(o.start, o.end, body);
  }

  /// Sets (or with a null [value], removes) a build setting in the
  /// XCBuildConfiguration [configId].
  void setBuildSetting(String configId, String key, String? value) {
    final o = object(configId);
    if (o == null) {
      throw ToolException('Build configuration $configId not found.');
    }
    var body = o.body.replaceAll(
      RegExp(
        '^\\t+${RegExp.escape(key)} = (?:\\([\\s\\S]*?\\)|.*?);\\n',
        multiLine: true,
      ),
      '',
    );
    if (value != null) {
      final settings = RegExp(
        r'^(\t+)buildSettings = \{\n',
        multiLine: true,
      ).firstMatch(body);
      if (settings == null) {
        throw ToolException(
          'Build configuration $configId has no buildSettings.',
        );
      }
      final line = '${settings[1]}\t$key = ${quote(value)};\n';
      body = body.replaceRange(settings.end, settings.end, line);
    }
    text = text.replaceRange(o.start, o.end, body);
  }

  /// The PBXNativeTarget named [name].
  String target(String name) {
    for (final id in idsOf('PBXNativeTarget')) {
      if (field(requireObject(id, 'target'), 'name') == name ||
          field(requireObject(id, 'target'), 'name') == '"$name"') {
        return id;
      }
    }
    throw ToolException(
      'project.pbxproj has no target named $name '
      '(set store_asset_packs: ios: target: in pubspec.yaml).',
    );
  }

  /// The build configurations of [targetOrProject].
  List<String> buildConfigurations(String targetOrProject) {
    final list = field(
      requireObject(targetOrProject, 'target'),
      'buildConfigurationList',
    );
    if (list == null) return [];
    return listIds(
      requireObject(list, 'configuration list'),
      'buildConfigurations',
    );
  }

  /// The target's build phase of [isa] (e.g. PBXResourcesBuildPhase).
  String? buildPhase(String target, String isa) {
    for (final id in listIds(requireObject(target, 'target'), 'buildPhases')) {
      final body = object(id)?.body ?? '';
      if (body.contains('isa = $isa;')) return id;
    }
    return null;
  }

  String get projectId {
    final m = RegExp(
      r'^\trootObject = ([0-9A-F]{24})',
      multiLine: true,
    ).firstMatch(text);
    if (m == null) throw ToolException('project.pbxproj has no rootObject.');
    return m[1]!;
  }

  /// Quotes a value the way Xcode does when it is not a plain identifier.
  static String quote(String value) =>
      RegExp(r'^[A-Za-z0-9_$/.:]+$').hasMatch(value) && !value.contains('//')
      ? value
      : '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}
