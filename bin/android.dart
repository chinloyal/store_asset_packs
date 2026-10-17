/// `dart run store_asset_packs:android [--check]`
///
/// Creates or refreshes `android/<pack>/build.gradle.kts` for every pack in
/// pubspec.yaml's store_asset_packs: section, and adds the packs to
/// settings.gradle.kts and app/build.gradle.kts. --check only reports whether
/// anything is out of date (exit status 1 if so).
// ignore_for_file: avoid_print
library;

import 'package:store_asset_packs/src/tool/android.dart';
import 'package:store_asset_packs/src/tool/config.dart';

Future<void> main(List<String> args) => runTool(() async {
  if (args.contains('-h') || args.contains('--help')) {
    print('Usage: dart run store_asset_packs:android [--check]');
    return;
  }
  await runAndroid(ProjectConfig.load(), check: args.contains('--check'));
});
