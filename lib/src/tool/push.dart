import 'dart:convert';
import 'dart:io';

import 'config.dart';

const devDirName = 'store_asset_packs_dev';

class PushOptions {
  PushOptions({
    this.device,
    this.packs = const [],
    this.appId,
    this.remove = false,
  });

  /// An adb serial, or a booted simulator's UDID or name.
  final String? device;
  final List<String> packs;

  /// The Android applicationId or iOS bundle id. Read from the project when
  /// null.
  final String? appId;

  /// Delete the packs from the dev-override directory instead of copying,
  /// to test real store delivery on a debug build.
  final bool remove;
}

class _Device {
  _Device(this.id, this.name, {required this.android});
  final String id;
  final String name;
  final bool android;
  @override
  String toString() => android ? '$name (adb $id)' : '$name (simulator $id)';
}

/// Copies pack source folders into a debug install's dev-override directory
/// on an Android device/emulator or a booted iOS simulator.
Future<void> runPush(ProjectConfig config, PushOptions options) async {
  final packs = config.select(options.packs);
  if (!options.remove) requireSources(packs);
  final device = await _pickDevice(options.device);
  if (device.android) {
    await _pushAndroid(config, device, packs, options);
  } else {
    await _pushSimulator(config, device, packs, options);
  }
}

Future<List<_Device>> _adbDevices() async {
  final ProcessResult result;
  try {
    result = await Process.run('adb', ['devices', '-l']);
  } on ProcessException {
    return [];
  }
  return [
    for (final line in LineSplitter.split('${result.stdout}').skip(1))
      if (RegExp(r'^(\S+)\s+device\b').firstMatch(line) case final m?)
        _Device(
          m[1]!,
          RegExp(r'model:(\S+)').firstMatch(line)?.group(1) ?? m[1]!,
          android: true,
        ),
  ];
}

Future<List<_Device>> _bootedSimulators() async {
  if (!Platform.isMacOS) return [];
  final result = await Process.run('xcrun', [
    'simctl',
    'list',
    'devices',
    'booted',
    '-j',
  ]);
  if (result.exitCode != 0) return [];
  final json = jsonDecode('${result.stdout}') as Map<String, Object?>;
  final runtimes = json['devices'] as Map<String, Object?>? ?? {};
  return [
    for (final list in runtimes.values)
      for (final d in (list as List).cast<Map<String, Object?>>())
        if (d['state'] == 'Booted')
          _Device(d['udid']! as String, d['name']! as String, android: false),
  ];
}

Future<_Device> _pickDevice(String? wanted) async {
  final devices = [...await _adbDevices(), ...await _bootedSimulators()];
  if (wanted != null) {
    for (final d in devices) {
      if (d.id == wanted || d.name == wanted) return d;
    }
    throw ToolException(
      'No connected Android device or booted simulator '
      'matches "$wanted". Found: ${devices.isEmpty ? 'none' : devices.join(', ')}',
    );
  }
  if (devices.length == 1) return devices.single;
  if (devices.isEmpty) {
    throw ToolException(
      'No Android device (adb devices) or booted iOS '
      'simulator found. Physical iPhones are not supported.',
    );
  }
  throw ToolException(
    'Several devices found; pick one with --device:\n  '
    '${devices.join('\n  ')}',
  );
}

Future<void> _pushAndroid(
  ProjectConfig config,
  _Device device,
  List<PackConfig> packs,
  PushOptions options,
) async {
  final appId = options.appId ?? androidApplicationId(config);
  final root = '/sdcard/Android/data/$appId/files/$devDirName';
  final adb = ['-s', device.id];
  // The app must create its external files dir first: a directory adb creates
  // before the install belongs to the shell user, and the app can't read it.
  final installed = await run('adb', [
    ...adb,
    'shell',
    'pm',
    'path',
    appId,
  ], allowFail: true);
  if (!'${installed.stdout}'.contains('package:')) {
    throw ToolException(
      '$appId is not installed on $device. Run the app '
      'there once (flutter run), then push again.',
    );
  }
  for (final pack in packs) {
    final dest = '$root/${pack.name}';
    if (options.remove) {
      await run('adb', [...adb, 'shell', 'rm', '-rf', dest]);
      stdout.writeln('Removed ${pack.name} from $device');
      continue;
    }
    await run('adb', [...adb, 'shell', 'mkdir', '-p', dest]);
    // --sync skips files whose size and timestamp match the device's copy.
    final result = await run('adb', [
      ...adb,
      'push',
      '--sync',
      '${pack.source.path}/.',
      dest,
    ]);
    final summary = LineSplitter.split(
      '${result.stdout}${result.stderr}',
    ).lastWhere((l) => l.contains('pushed'), orElse: () => 'done');
    stdout.writeln(
      '${pack.name} → $device: '
      '${summary.replaceFirst(RegExp(r'^.*?: '), '')}',
    );
  }
  if (!options.remove) {
    stdout.writeln('Debug builds of $appId now read these packs from $root.');
  }
}

Future<void> _pushSimulator(
  ProjectConfig config,
  _Device device,
  List<PackConfig> packs,
  PushOptions options,
) async {
  final bundleId = options.appId ?? iosBundleId(config);
  final container = await run('xcrun', [
    'simctl',
    'get_app_container',
    device.id,
    bundleId,
    'data',
  ], allowFail: true);
  if (container.exitCode != 0) {
    throw ToolException(
      '$bundleId is not installed on $device. Run the app '
      'there once (flutter run), then push again.',
    );
  }
  final root = '${'${container.stdout}'.trim()}/Documents/$devDirName';
  for (final pack in packs) {
    final dest = Directory('$root/${pack.name}');
    if (options.remove) {
      if (dest.existsSync()) dest.deleteSync(recursive: true);
      stdout.writeln('Removed ${pack.name} from $device');
      continue;
    }
    dest.createSync(recursive: true);
    // Mirrors the source folder, copying only what changed.
    final result = await run('rsync', [
      '-a',
      '--delete',
      '--stats',
      '${pack.source.path}/',
      '${dest.path}/',
    ]);
    final transferred =
        RegExp(
          r'Number of (?:regular )?files transferred: (\d+)',
        ).firstMatch('${result.stdout}')?.group(1) ??
        '?';
    stdout.writeln('${pack.name} → $device: $transferred files copied');
  }
  if (!options.remove) {
    stdout.writeln(
      'Debug builds of $bundleId now read these packs from $root.',
    );
  }
}

/// The applicationId in android/app/build.gradle.kts.
String androidApplicationId(ProjectConfig config) {
  final file = File('${config.androidDir.path}/app/build.gradle.kts');
  final match = file.existsSync()
      ? RegExp(
          r'''applicationId\s*=\s*"([^"]+)"''',
        ).firstMatch(file.readAsStringSync())
      : null;
  if (match == null) {
    throw ToolException(
      'Could not read applicationId from ${file.path}; '
      'pass --app-id.',
    );
  }
  return match[1]!;
}

/// The app target's bundle id in Runner.xcodeproj: the most common literal
/// PRODUCT_BUNDLE_IDENTIFIER that is not a test or extension target's.
String iosBundleId(ProjectConfig config) {
  final file = File('${config.iosDir.path}/Runner.xcodeproj/project.pbxproj');
  if (!file.existsSync()) {
    throw ToolException('No ${file.path}; pass --app-id.');
  }
  final counts = <String, int>{};
  for (final m in RegExp(
    r'PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;',
  ).allMatches(file.readAsStringSync())) {
    final id = m[1]!;
    if (id.contains(r'$') || id.endsWith('Tests')) continue;
    counts[id] = (counts[id] ?? 0) + 1;
  }
  if (counts.isEmpty) {
    throw ToolException(
      'Could not read the bundle id from ${file.path}; '
      'pass --app-id.',
    );
  }
  // Extensions are <app>.<suffix>: prefer the shortest id among the most used.
  final ids = counts.keys.toList()
    ..sort((a, b) => a.length.compareTo(b.length));
  return ids.first;
}
