@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:store_asset_packs/src/tool/android.dart';
import 'package:store_asset_packs/src/tool/config.dart';
import 'package:store_asset_packs/src/tool/ios.dart';
import 'package:store_asset_packs/src/tool/pbxproj.dart';
import 'package:store_asset_packs/src/tool/push.dart';

const _settings = '''
pluginManagement {
    repositories { google() }
}

plugins {
    id("com.android.application") version "9.0.1" apply false
}

include(":app")
''';

const _appBuild = '''
plugins {
    id("com.android.application")
}

android {
    namespace = "com.example.game"
    defaultConfig {
        applicationId = "com.example.game"
    }
}
''';

void main() {
  late Directory root;

  /// A Flutter app with two packs, and their source folders.
  Future<ProjectConfig> project(String section) async {
    File(
      '${root.path}/pubspec.yaml',
    ).writeAsStringSync('name: game\n\nstore_asset_packs:\n$section');
    return ProjectConfig.load(root);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('store_asset_packs_tool');
    for (final p in ['art/level2', 'art/level3/sub']) {
      Directory('${root.path}/$p').createSync(recursive: true);
    }
    File('${root.path}/art/level2/a.png').writeAsStringSync('a');
    File('${root.path}/art/level3/sub/b.png').writeAsStringSync('b');
    Directory('${root.path}/android/app').createSync(recursive: true);
    File(
      '${root.path}/android/settings.gradle.kts',
    ).writeAsStringSync(_settings);
    File(
      '${root.path}/android/app/build.gradle.kts',
    ).writeAsStringSync(_appBuild);
    Directory('${root.path}/ios/Runner.xcodeproj').createSync(recursive: true);
    Directory('${root.path}/ios/Runner').createSync(recursive: true);
    File(
      'test/fixtures/project.pbxproj',
    ).copySync('${root.path}/ios/Runner.xcodeproj/project.pbxproj');
    File(
      'test/fixtures/Info.plist',
    ).copySync('${root.path}/ios/Runner/Info.plist');
  });

  tearDown(() => root.delete(recursive: true));

  group('config', () {
    test('reads short and long pack forms with defaults', () async {
      final config = await project('''
  packs:
    level2: art/level2
    level3:
      source: art/level3
      android_delivery_type: on-demand
      ios_download_policy: essential
  android:
    delivery_type: fast-follow
''');
      expect(config.packs.map((p) => p.name), ['level2', 'level3']);
      expect(config.packs[0].source.path, '${root.absolute.path}/art/level2');
      expect(config.packs[0].androidDeliveryType, 'fast-follow');
      expect(config.packs[0].iosDownloadPolicy, 'prefetch');
      expect(config.packs[1].androidDeliveryType, 'on-demand');
      expect(config.packs[1].iosDownloadPolicy, 'essential');
      expect(config.iosTarget, 'Runner');
      expect(config.iosBackgroundAssets, isFalse);
    });

    test('rejects bad names and values', () async {
      await expectLater(
        project('  packs:\n    2bad: art/level2\n'),
        throwsA(isA<ToolException>()),
      );
      await expectLater(
        project(
          '  packs:\n    ok: art/level2\n  android:\n    delivery_type: soon\n',
        ),
        throwsA(isA<ToolException>()),
      );
    });

    test('needs a section', () async {
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: game\n');
      expect(() => ProjectConfig.load(root), throwsA(isA<ToolException>()));
    });

    test('relativePath', () {
      expect(relativePath('/a/b/c', '/a/d'), '../b/c');
      expect(relativePath('/a/b', '/a/b'), '.');
    });
  });

  group('android', () {
    test('generates modules and wires them in, idempotently', () async {
      final config = await project('''
  packs:
    level2: art/level2
    level3:
      source: art/level3
      android_delivery_type: on-demand
''');
      await runAndroid(config);
      final build = File(
        '${root.path}/android/level2/build.gradle.kts',
      ).readAsStringSync();
      expect(build, contains('id("com.android.asset-pack")'));
      expect(build, contains('packName.set("level2")'));
      expect(build, contains('deliveryType.set("fast-follow")'));
      expect(build, contains('from(file("../../art/level2"))'));
      expect(build, contains('src/main/assets/level2'));
      expect(
        File('${root.path}/android/level3/build.gradle.kts').readAsStringSync(),
        contains('deliveryType.set("on-demand")'),
      );
      expect(
        File('${root.path}/android/level2/.gitignore').readAsStringSync(),
        contains('/src/main/assets/'),
      );

      final settings = File(
        '${root.path}/android/settings.gradle.kts',
      ).readAsStringSync();
      expect(
        settings,
        contains('include(":app")\n// store_asset_packs: begin'),
      );
      expect(settings, contains('include(":level2", ":level3")'));
      final app = File(
        '${root.path}/android/app/build.gradle.kts',
      ).readAsStringSync();
      expect(app, contains('android {\n    // store_asset_packs: begin'));
      expect(app, contains('    assetPacks += listOf(":level2", ":level3")'));

      // A second run changes nothing; --check agrees.
      await runAndroid(config);
      expect(
        File('${root.path}/android/settings.gradle.kts').readAsStringSync(),
        settings,
      );
      exitCode = 0;
      await runAndroid(config, check: true);
      expect(exitCode, 0);
    });

    test('updates the block when packs change', () async {
      await runAndroid(await project('  packs:\n    level2: art/level2\n'));
      await runAndroid(
        await project(
          '  packs:\n    level2: art/level2\n    level3: art/level3\n',
        ),
      );
      final settings = File(
        '${root.path}/android/settings.gradle.kts',
      ).readAsStringSync();
      expect(':level2'.allMatches(settings).length, 1);
      expect(settings, contains('include(":level2", ":level3")'));
    });

    test('refuses to overwrite a hand-written module', () async {
      File('${root.path}/android/level2/build.gradle.kts')
        ..createSync(recursive: true)
        ..writeAsStringSync('// mine');
      await expectLater(
        runAndroid(await project('  packs:\n    level2: art/level2\n')),
        throwsA(isA<ToolException>()),
      );
    });

    test('reads the applicationId', () async {
      expect(
        androidApplicationId(
          await project('  packs:\n    level2: art/level2\n'),
        ),
        'com.example.game',
      );
    });
  });

  group('ios odr', () {
    File pbxFile() => File('${root.path}/ios/Runner.xcodeproj/project.pbxproj');

    test('adds tagged folder references, idempotently', () async {
      final config = await project('''
  packs:
    level2:
      source: art/level2
      ios_download_policy: essential
    level3:
      source: art/level3
      ios_download_policy: onDemand
''');
      await runIosOdr(config);
      final text = pbxFile().readAsStringSync();
      final fileId = PbxProject.id('01', 'file:level2');
      expect(
        text,
        contains(
          '$fileId /* level2 */ = {isa = PBXFileReference; '
          'lastKnownFileType = folder; name = level2; path = ../art/level2; '
          'sourceTree = SOURCE_ROOT; };',
        ),
      );
      expect(text, contains('settings = {ASSET_TAGS = (level2, ); }; };'));
      expect(
        text,
        contains('knownAssetTags = (\n\t\t\t\t\tlevel2,\n\t\t\t\t\tlevel3,\n'),
      );
      expect(
        text,
        contains('ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS = level2;'),
      );
      expect(text, isNot(contains('ON_DEMAND_RESOURCES_PREFETCH_ORDER')));
      expect(
        'EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE = YES;'.allMatches(text).length,
        1,
      );
      // Referenced once from the Resources phase and once from the group.
      expect('$fileId /* level2 */,'.allMatches(text).length, 1);
      expect(
        '${PbxProject.id('01', 'build:level2')} /* level2 in Resources */,'
            .allMatches(text)
            .length,
        1,
      );

      await runIosOdr(config);
      expect(pbxFile().readAsStringSync(), text);
    });

    test('removing a pack removes its objects', () async {
      await runIosOdr(
        await project(
          '  packs:\n    level2: art/level2\n    level3: art/level3\n',
        ),
      );
      await runIosOdr(await project('  packs:\n    level2: art/level2\n'));
      final text = pbxFile().readAsStringSync();
      expect(text, isNot(contains(PbxProject.id('01', 'file:level3'))));
      expect(text, contains(PbxProject.id('01', 'file:level2')));
    });

    test('requires folders named after packs', () async {
      await expectLater(
        runIosOdr(await project('  packs:\n    other: art/level2\n')),
        throwsA(isA<ToolException>()),
      );
    });

    test('reads the bundle id', () async {
      expect(
        iosBundleId(await project('  packs:\n    level2: art/level2\n')),
        'com.potudo.storeAssetPacksExample',
      );
    });
  });

  group('ios background assets', () {
    test(
      'edits existing plists textually',
      () async {
        final config = await project('  packs:\n    level2: art/level2\n');
        // An app that already has commented Info.plist and entitlements.
        final infoFile = File('${root.path}/ios/Runner/Info.plist');
        final info = infoFile.readAsStringSync().replaceFirst(
          '<dict>\n',
          '<dict>\n\t<!-- why this key exists -->\n'
              '\t<key>SKAdNetworkItems</key>\n\t<array>\n'
              '\t\t<dict><key>SKAdNetworkIdentifier</key><string>x.skadnetwork</string></dict>\n'
              '\t</array>\n',
        );
        infoFile.writeAsStringSync(info);
        final entFile = File('${root.path}/ios/Runner/Runner.entitlements');
        const ent =
            '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
            '\t<!-- Game Center -->\n\t<key>com.apple.developer.game-center</key>\n'
            '\t<true/>\n</dict>\n</plist>\n';
        entFile.writeAsStringSync(ent);
        final pbxFile = File(
          '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
        );
        final pbx = PbxProject(pbxFile.readAsStringSync());
        for (final c in pbx.buildConfigurations(pbx.target('Runner'))) {
          pbx.setBuildSetting(
            c,
            'CODE_SIGN_ENTITLEMENTS',
            'Runner/Runner.entitlements',
          );
        }
        pbxFile.writeAsStringSync(pbx.text);

        exitCode = 0;
        await runIosBackgroundAssets(config, check: true);
        expect(exitCode, 1);
        exitCode = 0;

        await runIosBackgroundAssets(config);
        expect(
          infoFile.readAsStringSync(),
          info.replaceFirst(
            '</dict>\n</plist>',
            '\t<key>BAHasManagedAssetPacks</key>\n\t<true/>\n'
                '\t<key>BAUsesAppleHosting</key>\n\t<true/>\n'
                '\t<key>BAAppGroupID</key>\n'
                '\t<string>group.com.potudo.storeAssetPacksExample</string>\n'
                '</dict>\n</plist>',
          ),
        );
        expect(
          entFile.readAsStringSync(),
          ent.replaceFirst(
            '\t<true/>\n</dict>',
            '\t<true/>\n\t<key>com.apple.security.application-groups</key>\n'
                '\t<array>\n\t\t<string>group.com.potudo.storeAssetPacksExample</string>\n'
                '\t</array>\n</dict>',
          ),
        );
        final lint = await Process.run('plutil', [
          '-lint',
          entFile.path,
          infoFile.path,
        ]);
        expect(lint.exitCode, 0, reason: '${lint.stdout}');

        await runIosBackgroundAssets(config, check: true);
        expect(exitCode, 0);
      },
      skip: Platform.isMacOS ? false : 'needs plutil',
    );

    test(
      'adds keys, entitlements and the extension target',
      () async {
        final config = await project('  packs:\n    level2: art/level2\n');
        await runIosBackgroundAssets(config);
        final info = File(
          '${root.path}/ios/Runner/Info.plist',
        ).readAsStringSync();
        expect(info, contains('<key>BAHasManagedAssetPacks</key>\n\t<true/>'));
        expect(
          info,
          contains('<string>group.com.potudo.storeAssetPacksExample</string>'),
        );
        expect(
          File(
            '${root.path}/ios/Runner/Runner.entitlements',
          ).readAsStringSync(),
          contains('group.com.potudo.storeAssetPacksExample'),
        );
        expect(
          File(
            '${root.path}/ios/AssetPackDownloader/DownloaderExtension.swift',
          ).readAsStringSync(),
          contains('StoreDownloaderExtension'),
        );
        final text = File(
          '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
        ).readAsStringSync();
        expect(
          text,
          contains(
            'productType = "com.apple.product-type.extensionkit-extension";',
          ),
        );
        expect(
          text,
          contains(
            'PRODUCT_BUNDLE_IDENTIFIER = '
            'com.potudo.storeAssetPacksExample.AssetPackDownloader;',
          ),
        );
        expect(
          text,
          contains('CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'),
        );
        // The embed phase sits right after the app's Resources phase.
        expect(
          text,
          contains(
            '/* Resources */,\n\t\t\t\t'
            '${PbxProject.id('02', 'embed')} /* Embed ExtensionKit Extensions */,',
          ),
        );
        final lint = await Process.run('plutil', [
          '-lint',
          '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
        ]);
        expect(lint.exitCode, 0, reason: '${lint.stdout}');

        await runIosBackgroundAssets(config);
        expect(
          File(
            '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
          ).readAsStringSync(),
          text,
        );
      },
      skip: Platform.isMacOS ? false : 'needs plutil',
    );
  });
}
