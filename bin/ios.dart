/// `dart run store_asset_packs:ios [odr|background-assets|package] [--check] [--pack <name>]...`
///
/// - odr: tags each pack's folder for On-Demand Resources in Runner.xcodeproj.
/// - background-assets: Info.plist keys, app group entitlements and the
///   downloader extension target for Apple-hosted Background Assets.
/// - package: builds each pack's .aar archive for App Store Connect.
///
/// With no subcommand, runs odr, plus background-assets when the
/// store_asset_packs: ios: section sets background_assets: true.
// ignore_for_file: avoid_print
library;

import 'package:args/args.dart';
import 'package:store_asset_packs/src/tool/config.dart';
import 'package:store_asset_packs/src/tool/ios.dart';

Future<void> main(List<String> arguments) => runTool(() async {
  final parser = ArgParser()
    ..addFlag(
      'check',
      negatable: false,
      help: 'Only report whether the project is out of date (exit 1 if so).',
    )
    ..addMultiOption(
      'pack',
      abbr: 'p',
      help: 'package: only these packs (default: all).',
    )
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    throw ToolException('${e.message}\n\n${parser.usage}');
  }
  const usage =
      'Usage: dart run store_asset_packs:ios '
      '[odr|background-assets|package] [options]';
  if (args.flag('help')) {
    print('$usage\n\n${parser.usage}');
    return;
  }
  final config = ProjectConfig.load();
  final check = args.flag('check');
  switch (args.rest.firstOrNull) {
    case null:
      await runIosOdr(config, check: check);
      if (config.iosBackgroundAssets) {
        await runIosBackgroundAssets(config, check: check);
      }
    case 'odr':
      await runIosOdr(config, check: check);
    case 'background-assets':
      await runIosBackgroundAssets(config, check: check);
    case 'package':
      await runIosPackage(config, args.multiOption('pack'));
    case final other:
      throw ToolException('Unknown subcommand "$other".\n$usage');
  }
});
