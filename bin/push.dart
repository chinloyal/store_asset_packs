/// `dart run store_asset_packs:push [--device <id>] [--pack <name>]... [--app-id <id>] [--remove]`
///
/// Copies pack source folders into the dev-override directory of a debug
/// install, on an Android device/emulator (adb) or a booted iOS simulator, so
/// `flutter run` builds see the packs as installed. Only changed files are
/// copied. --remove deletes them again, to test real store delivery.
// ignore_for_file: avoid_print
library;

import 'package:args/args.dart';
import 'package:store_asset_packs/src/tool/config.dart';
import 'package:store_asset_packs/src/tool/push.dart';

Future<void> main(List<String> arguments) => runTool(() async {
  final parser = ArgParser()
    ..addOption(
      'device',
      abbr: 'd',
      help:
          'adb serial, or a booted simulator\'s UDID or name. '
          'Needed when more than one is connected.',
    )
    ..addMultiOption(
      'pack',
      abbr: 'p',
      help: 'Only these packs (default: all).',
    )
    ..addOption(
      'app-id',
      help:
          'Android applicationId or iOS bundle id (default: read from '
          'the project).',
    )
    ..addFlag(
      'remove',
      negatable: false,
      help: 'Delete the packs from the device\'s dev-override directory.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    throw ToolException('${e.message}\n\n${parser.usage}');
  }
  if (args.flag('help')) {
    print(
      'Usage: dart run store_asset_packs:push [options]\n\n${parser.usage}',
    );
    return;
  }
  await runPush(
    ProjectConfig.load(),
    PushOptions(
      device: args.option('device'),
      packs: args.multiOption('pack'),
      appId: args.option('app-id'),
      remove: args.flag('remove'),
    ),
  );
});
