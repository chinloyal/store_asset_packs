// Pure Dart (no Flutter imports): used by the `dart run store_asset_packs:*`
// commands.
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Thrown for problems the user must fix; the commands print the message and
/// exit with status 1, without a stack trace.
class ToolException implements Exception {
  ToolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Play's delivery modes. install-time packs live inside the APK, so
/// `getPackPath` cannot return a directory for them.
const androidDeliveryTypes = {'install-time', 'fast-follow', 'on-demand'};

/// Background Assets download policies, also mapped onto ODR: essential →
/// initial-install tags, prefetch → prefetched tag order, onDemand → neither.
const iosDownloadPolicies = {'essential', 'prefetch', 'onDemand'};

final _packName = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

class PackConfig {
  PackConfig({
    required this.name,
    required this.source,
    required this.androidDeliveryType,
    required this.iosDownloadPolicy,
  });

  final String name;

  /// The source folder, absolute.
  final Directory source;
  final String androidDeliveryType;
  final String iosDownloadPolicy;
}

class ProjectConfig {
  ProjectConfig({
    required this.root,
    required this.packs,
    required this.iosTarget,
    required this.iosAppGroup,
    required this.iosExtensionName,
    required this.iosBackgroundAssets,
  });

  /// The Flutter app's root (the folder holding pubspec.yaml).
  final Directory root;
  final List<PackConfig> packs;

  /// The Xcode app target that gets the ODR folders and the downloader
  /// extension. Default Runner.
  final String iosTarget;

  /// The app group the app and its Background Assets extension share. Null
  /// means `group.<bundle id>`.
  final String? iosAppGroup;

  /// The downloader extension's target name.
  final String iosExtensionName;

  /// Whether `store_asset_packs:ios` also sets up Background Assets.
  final bool iosBackgroundAssets;

  Directory get androidDir => Directory('${root.path}/android');
  Directory get iosDir => Directory('${root.path}/ios');
  Directory get buildDir => Directory('${root.path}/build/store_asset_packs');

  /// Packs named in [only], or all of them.
  List<PackConfig> select(List<String> only) {
    if (only.isEmpty) return packs;
    final unknown = only.where((n) => !packs.any((p) => p.name == n));
    if (unknown.isNotEmpty) {
      throw ToolException(
        'Unknown pack(s): ${unknown.join(', ')}. '
        'Configured: ${packs.map((p) => p.name).join(', ')}',
      );
    }
    return packs.where((p) => only.contains(p.name)).toList();
  }

  /// Reads the `store_asset_packs:` section of pubspec.yaml, or
  /// store_asset_packs.yaml, in [root] (default: the current directory).
  static ProjectConfig load([Directory? root]) {
    root ??= Directory.current;
    final pubspec = File('${root.path}/pubspec.yaml');
    final standalone = File('${root.path}/store_asset_packs.yaml');
    if (!pubspec.existsSync()) {
      throw ToolException(
        'No pubspec.yaml in ${root.path}. Run this from your app\'s root.',
      );
    }
    Object? section;
    String origin;
    if (standalone.existsSync()) {
      section = loadYaml(standalone.readAsStringSync());
      origin = standalone.path;
    } else {
      final doc = loadYaml(pubspec.readAsStringSync());
      section = doc is YamlMap ? doc['store_asset_packs'] : null;
      origin = '${pubspec.path} (store_asset_packs:)';
    }
    if (section is! YamlMap) {
      throw ToolException(
        'No store_asset_packs configuration found. Add a '
        '`store_asset_packs:` section to pubspec.yaml, for example:\n\n'
        'store_asset_packs:\n'
        '  packs:\n'
        '    level_art: assets/level_art\n',
      );
    }

    final android = _map(section['android'], 'android', origin);
    final ios = _map(section['ios'], 'ios', origin);
    final defaultDelivery = _choice(
      android['delivery_type'],
      androidDeliveryTypes,
      'fast-follow',
      'android.delivery_type',
      origin,
    );
    final defaultPolicy = _choice(
      ios['download_policy'],
      iosDownloadPolicies,
      'prefetch',
      'ios.download_policy',
      origin,
    );

    final packsNode = section['packs'];
    if (packsNode is! YamlMap || packsNode.isEmpty) {
      throw ToolException('$origin: `packs:` must map pack names to folders.');
    }
    final packs = <PackConfig>[];
    for (final entry in packsNode.entries) {
      final name = '${entry.key}';
      if (!_packName.hasMatch(name)) {
        throw ToolException(
          '$origin: pack name "$name" must start with a '
          'letter and contain only letters, digits and underscores (Play and '
          'Gradle require it).',
        );
      }
      final value = entry.value;
      final Map<Object?, Object?> fields = value is String
          ? {'source': value}
          : _map(value, 'packs.$name', origin);
      final source = fields['source'];
      if (source is! String) {
        throw ToolException('$origin: packs.$name needs a source folder.');
      }
      final dir = Directory(
        File(source).isAbsolute ? source : '${root.path}/$source',
      );
      packs.add(
        PackConfig(
          name: name,
          source: Directory(
            _trimSlash(dir.absolute.uri.normalizePath().toFilePath()),
          ),
          androidDeliveryType: _choice(
            fields['android_delivery_type'],
            androidDeliveryTypes,
            defaultDelivery,
            'packs.$name.android_delivery_type',
            origin,
          ),
          iosDownloadPolicy: _choice(
            fields['ios_download_policy'],
            iosDownloadPolicies,
            defaultPolicy,
            'packs.$name.ios_download_policy',
            origin,
          ),
        ),
      );
    }
    return ProjectConfig(
      root: root.absolute,
      packs: packs,
      iosTarget: (ios['target'] as String?) ?? 'Runner',
      iosAppGroup: ios['app_group'] as String?,
      iosExtensionName:
          (ios['extension_name'] as String?) ?? 'AssetPackDownloader',
      iosBackgroundAssets: ios['background_assets'] == true,
    );
  }

  static String _trimSlash(String path) => path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;

  static Map<Object?, Object?> _map(Object? node, String key, String origin) {
    if (node == null) return const {};
    if (node is YamlMap) return node;
    throw ToolException('$origin: `$key` must be a map.');
  }

  static String _choice(
    Object? value,
    Set<String> allowed,
    String fallback,
    String key,
    String origin,
  ) {
    if (value == null) return fallback;
    if (value is String && allowed.contains(value)) return value;
    throw ToolException(
      '$origin: `$key` is "$value"; use one of ${allowed.join(', ')}.',
    );
  }
}

/// Checks each pack's source folder exists and holds files.
void requireSources(Iterable<PackConfig> packs) {
  for (final pack in packs) {
    if (!pack.source.existsSync()) {
      throw ToolException(
        'Pack ${pack.name}: source folder ${pack.source.path} does not exist.',
      );
    }
  }
}

/// [to] relative to the directory [from], with forward slashes.
String relativePath(String to, String from) {
  final a = Directory(to).absolute.uri
      .normalizePath()
      .pathSegments
      .where((s) => s.isNotEmpty)
      .toList();
  final b = Directory(from).absolute.uri
      .normalizePath()
      .pathSegments
      .where((s) => s.isNotEmpty)
      .toList();
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  final parts = [for (var j = i; j < b.length; j++) '..', ...a.sublist(i)];
  return parts.isEmpty ? '.' : parts.map(Uri.decodeComponent).join('/');
}

/// Runs a [ToolException]-throwing command body, printing errors cleanly.
Future<void> runTool(Future<void> Function() body) async {
  try {
    await body();
  } on ToolException catch (e) {
    stderr.writeln('store_asset_packs: $e');
    exitCode = 1;
  }
}

/// Runs a process, throwing a [ToolException] with its output if it fails.
Future<ProcessResult> run(
  String exe,
  List<String> args, {
  String? workingDirectory,
  bool allowFail = false,
}) async {
  final result = await Process.run(
    exe,
    args,
    workingDirectory: workingDirectory,
    runInShell: false,
  );
  if (result.exitCode != 0 && !allowFail) {
    throw ToolException(
      '`$exe ${args.join(' ')}` failed '
      '(${result.exitCode}):\n${result.stdout}${result.stderr}',
    );
  }
  return result;
}
