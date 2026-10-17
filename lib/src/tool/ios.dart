import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'pbxproj.dart';
import 'plist_text.dart';
import 'push.dart' show iosBundleId;

/// ID kinds (see [PbxProject.id]).
const _kOdr = '01'; // ODR folder references, their build files and group
const _kExt = '02'; // the Background Assets downloader extension

/// Adds each pack's source folder to the app target as a folder reference
/// tagged with the pack's name, for On-Demand Resources (iOS 15–25, and any
/// iOS when Background Assets is not set up).
Future<void> runIosOdr(ProjectConfig config, {bool check = false}) async {
  requireSources(config.packs);
  for (final pack in config.packs) {
    final folder = pack.source.path.split('/').last;
    if (folder != pack.name) {
      throw ToolException(
        'Pack ${pack.name}: its folder is named "$folder". '
        'On iOS a folder reference keeps its folder name in the app bundle, '
        'so the folder must be named after the pack.',
      );
    }
  }
  final file = _pbxprojFile(config);
  final pbx = PbxProject(file.readAsStringSync());
  final before = pbx.text;
  final target = pbx.target(config.iosTarget);
  final resources = pbx.buildPhase(target, 'PBXResourcesBuildPhase');
  if (resources == null) {
    throw ToolException('Target ${config.iosTarget} has no Resources phase.');
  }

  pbx.removeOwn(_kOdr);

  final groupId = PbxProject.id(_kOdr, 'group');
  final children = <String>[];
  for (final pack in config.packs.reversed) {
    final fileId = PbxProject.id(_kOdr, 'file:${pack.name}');
    final buildId = PbxProject.id(_kOdr, 'build:${pack.name}');
    final path = relativePath(pack.source.path, config.iosDir.path);
    pbx.addObject(
      'PBXFileReference',
      '\t\t$fileId /* ${pack.name} */ = {isa = PBXFileReference; '
          'lastKnownFileType = folder; name = ${PbxProject.quote(pack.name)}; '
          'path = ${PbxProject.quote(path)}; sourceTree = SOURCE_ROOT; };',
    );
    pbx.addObject(
      'PBXBuildFile',
      '\t\t$buildId /* ${pack.name} in Resources */ = {isa = PBXBuildFile; '
          'fileRef = $fileId /* ${pack.name} */; settings = {ASSET_TAGS = '
          '(${PbxProject.quote(pack.name)}, ); }; };',
    );
    children.insert(0, '$fileId /* ${pack.name} */');
  }
  pbx.addObject(
    'PBXGroup',
    '\t\t$groupId /* StoreAssetPacks */ = {\n'
        '\t\t\tisa = PBXGroup;\n'
        '\t\t\tchildren = (\n'
        '${children.map((c) => '\t\t\t\t$c,\n').join()}'
        '\t\t\t);\n'
        '\t\t\tname = StoreAssetPacks;\n'
        '\t\t\tsourceTree = "<group>";\n'
        '\t\t};',
  );
  final project = pbx.requireObject(pbx.projectId, 'project');
  final mainGroup = PbxProject.field(project, 'mainGroup')!;
  pbx.addToList(mainGroup, 'children', ['$groupId /* StoreAssetPacks */']);
  pbx.addToList(resources, 'files', [
    for (final pack in config.packs)
      '${PbxProject.id(_kOdr, 'build:${pack.name}')} /* ${pack.name} in Resources */',
  ]);

  _setKnownAssetTags(pbx, config.packs.map((p) => p.name));

  String? tags(String policy) {
    final names = config.packs
        .where((p) => p.iosDownloadPolicy == policy)
        .map((p) => p.name);
    return names.isEmpty ? null : names.join(' ');
  }

  for (final configuration in pbx.buildConfigurations(target)) {
    pbx.setBuildSetting(
      configuration,
      'ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS',
      tags('essential'),
    );
    pbx.setBuildSetting(
      configuration,
      'ON_DEMAND_RESOURCES_PREFETCH_ORDER',
      tags('prefetch'),
    );
    pbx.setBuildSetting(configuration, 'ENABLE_ON_DEMAND_RESOURCES', 'YES');
    // Debug builds carry the packs inside the .app, so ODR serves them locally
    // to `flutter run` installs (only Xcode's Run hosts unembedded packs).
    // Release builds leave them out for the App Store to host.
    final name =
        PbxProject.field(
          pbx.requireObject(configuration, 'build configuration'),
          'name',
        ) ??
        '';
    pbx.setBuildSetting(
      configuration,
      'EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE',
      name.toLowerCase().contains('debug') ? 'YES' : null,
    );
  }

  _report(config, file, before, pbx.text, check, 'On-Demand Resources');
  for (final pack in config.packs) {
    final odr = switch (pack.iosDownloadPolicy) {
      'essential' => 'initial install tag',
      'prefetch' => 'prefetched tag',
      _ => 'on demand',
    };
    stdout.writeln(
      '  ${pack.name}: $odr ← '
      '${relativePath(pack.source.path, config.root.path)}',
    );
  }
}

void _setKnownAssetTags(PbxProject pbx, Iterable<String> names) {
  final o = pbx.object(pbx.projectId)!;
  var body = o.body;
  final existing = RegExp(
    r'^(\t+)knownAssetTags = \(\n([\s\S]*?)^\t+\);\n',
    multiLine: true,
  ).firstMatch(body);
  final tags = <String>{
    if (existing != null)
      for (final m in RegExp(
        r'^\t+"?([^",\n]+)"?,',
        multiLine: true,
      ).allMatches(existing[2]!))
        m[1]!,
    ...names,
  };
  final attributes = RegExp(
    r'^(\t+)attributes = \{\n',
    multiLine: true,
  ).firstMatch(body);
  if (attributes == null) throw ToolException('PBXProject has no attributes.');
  final indent = '${attributes[1]}\t';
  final block =
      '${indent}knownAssetTags = (\n'
      '${tags.map((t) => '$indent\t${PbxProject.quote(t)},\n').join()}'
      '$indent);\n';
  if (existing != null) {
    body = body.replaceRange(existing.start, existing.end, block);
  } else {
    body = body.replaceRange(attributes.end, attributes.end, block);
  }
  pbx.text = pbx.text.replaceRange(o.start, o.end, body);
}

File _pbxprojFile(ProjectConfig config) {
  final file = File('${config.iosDir.path}/Runner.xcodeproj/project.pbxproj');
  if (!file.existsSync()) throw ToolException('No ${file.path}.');
  return file;
}

void _report(
  ProjectConfig config,
  File file,
  String before,
  String after,
  bool check,
  String what,
) {
  final name = relativePath(file.path, config.root.path);
  // Regenerated entries may land in a different order; that's not a change.
  List<String> lines(String t) => t.split('\n')..sort();
  if (before == after || _listEquals(lines(before), lines(after))) {
    stdout.writeln('$what: $name is up to date.');
  } else if (check) {
    stdout.writeln('$what: $name is out of date.');
    exitCode = 1;
  } else {
    file.writeAsStringSync(after);
    stdout.writeln('$what: updated $name.');
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Background Assets

/// Sets the app up for Apple-hosted Background Assets: the Info.plist keys,
/// the app group on the app and its downloader extension, and the extension
/// target itself (created once; later runs leave its settings alone).
Future<void> runIosBackgroundAssets(
  ProjectConfig config, {
  bool check = false,
}) async {
  final ios = config.iosDir;
  final bundleId = iosBundleId(config);
  final group = config.iosAppGroup ?? 'group.$bundleId';
  final extName = config.iosExtensionName;
  final changes = <String>[];

  // Info.plist keys, edited textually so comments and formatting survive.
  final infoPlist = File('${ios.path}/Runner/Info.plist');
  if (!infoPlist.existsSync()) throw ToolException('No ${infoPlist.path}.');
  final info = PlistText(infoPlist.readAsStringSync());
  final before = info.text;
  info
    ..set('BAHasManagedAssetPacks', '<true/>')
    ..set('BAUsesAppleHosting', '<true/>')
    ..set('BAAppGroupID', '<string>${PlistText.escape(group)}</string>');
  if (info.text != before) {
    changes.add('ios/Runner/Info.plist');
    if (!check) infoPlist.writeAsStringSync(info.text);
  }

  final file = _pbxprojFile(config);
  final pbx = PbxProject(file.readAsStringSync());
  final pbxBefore = pbx.text;
  final app = pbx.target(config.iosTarget);
  final appConfigs = pbx.buildConfigurations(app);

  // The app's entitlements: reuse CODE_SIGN_ENTITLEMENTS if set.
  final appEntitlementsSetting = appConfigs
      .map((c) => _buildSetting(pbx, c, 'CODE_SIGN_ENTITLEMENTS'))
      .whereType<String>()
      .toSet();
  final appEntitlementsPaths = appEntitlementsSetting.isEmpty
      ? {'Runner/Runner.entitlements'}
      : appEntitlementsSetting;
  for (final path in appEntitlementsPaths) {
    final entitlements = File('${ios.path}/$path');
    if (_ensureAppGroup(entitlements, group, check)) {
      changes.add(relativePath(entitlements.path, config.root.path));
    }
  }
  if (appEntitlementsSetting.isEmpty) {
    for (final c in appConfigs) {
      pbx.setBuildSetting(
        c,
        'CODE_SIGN_ENTITLEMENTS',
        'Runner/Runner.entitlements',
      );
    }
    _addFileToGroup(
      pbx,
      config,
      'Runner/Runner.entitlements',
      PbxProject.id(_kExt, 'app-entitlements'),
    );
  }

  // The extension's files.
  final extDir = Directory('${ios.path}/$extName');
  final sources = {
    'DownloaderExtension.swift': _extensionSwift,
    'Info.plist': _extensionInfoPlist,
    '$extName.entitlements': _entitlements(group),
  };
  for (final e in sources.entries) {
    final f = File('${extDir.path}/${e.key}');
    if (!f.existsSync()) {
      changes.add(relativePath(f.path, config.root.path));
      if (!check) {
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(e.value);
      }
    } else if (e.key.endsWith('.entitlements') &&
        _ensureAppGroup(f, group, check)) {
      changes.add(relativePath(f.path, config.root.path));
    }
  }

  // The extension target, once.
  final hasTarget = pbx
      .idsOf('PBXNativeTarget')
      .any(
        (id) =>
            PbxProject.field(pbx.requireObject(id, 'target'), 'name') ==
            extName,
      );
  if (!hasTarget) {
    _addExtensionTarget(pbx, config, app, appConfigs, bundleId, extName);
  }

  if (pbx.text != pbxBefore) {
    changes.add(relativePath(file.path, config.root.path));
    if (!check) file.writeAsStringSync(pbx.text);
  }

  if (changes.isEmpty) {
    stdout.writeln('Background Assets: up to date.');
  } else if (check) {
    stdout.writeln('Background Assets: out of date: ${changes.join(', ')}');
    exitCode = 1;
  } else {
    stdout.writeln('Background Assets: updated ${changes.join(', ')}');
  }
  stdout.writeln(
    '  app group: $group (register it for $bundleId and '
    '$bundleId.$extName in the Apple Developer portal, or let Xcode\'s '
    'automatic signing do it)',
  );
}

String? _buildSetting(PbxProject pbx, String config, String key) {
  final body = pbx.requireObject(config, 'build configuration');
  final v = PbxProject.field(body, key);
  return v?.replaceAll('"', '');
}

/// Adds [group] to the entitlements file's app groups, creating the file if
/// needed. Edits are textual: the rest of the file stays as it was. Returns
/// whether it changed (or would change, with [check]).
bool _ensureAppGroup(File file, String group, bool check) {
  if (!file.existsSync()) {
    if (!check) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_entitlements(group));
    }
    return true;
  }
  final before = file.readAsStringSync();
  final plist = PlistText(before)
    ..addString('com.apple.security.application-groups', group);
  if (plist.text == before) return false;
  if (!check) file.writeAsStringSync(plist.text);
  return true;
}

void _addFileToGroup(
  PbxProject pbx,
  ProjectConfig config,
  String path,
  String fileId,
) {
  if (pbx.object(fileId) != null) return;
  final name = path.split('/').last;
  pbx.addObject(
    'PBXFileReference',
    '\t\t$fileId /* $name */ = {isa = PBXFileReference; '
        'lastKnownFileType = text.plist.entitlements; '
        'name = ${PbxProject.quote(name)}; path = ${PbxProject.quote(path)}; '
        'sourceTree = SOURCE_ROOT; };',
  );
  final project = pbx.requireObject(pbx.projectId, 'project');
  pbx.addToList(PbxProject.field(project, 'mainGroup')!, 'children', [
    '$fileId /* $name */',
  ]);
}

/// Adds an ExtensionKit downloader-extension target embedded in [app],
/// mirroring Xcode's "Background Download Extension (Apple-Hosted, Managed)"
/// template.
void _addExtensionTarget(
  PbxProject pbx,
  ProjectConfig config,
  String app,
  List<String> appConfigs,
  String bundleId,
  String extName,
) {
  String id(String key) => PbxProject.id(_kExt, key);
  final product = id('product');
  final swiftRef = id('swift');
  final plistRef = id('plist');
  final entRef = id('entitlements');
  final swiftBuild = id('swift-build');
  final embedBuild = id('embed-build');
  final sources = id('sources');
  final frameworks = id('frameworks');
  final resources = id('resources');
  final embed = id('embed');
  final group = id('group');
  final target = id('target');
  final configList = id('config-list');
  final proxy = id('proxy');
  final dependency = id('dependency');

  pbx.addObject(
    'PBXFileReference',
    '\t\t$product /* $extName.appex */ = {isa = PBXFileReference; '
        'explicitFileType = "wrapper.extensionkit-extension"; includeInIndex = 0; '
        'path = $extName.appex; sourceTree = BUILT_PRODUCTS_DIR; };',
  );
  pbx.addObject(
    'PBXFileReference',
    '\t\t$swiftRef /* DownloaderExtension.swift */ = {isa = PBXFileReference; '
        'lastKnownFileType = sourcecode.swift; path = DownloaderExtension.swift; '
        'sourceTree = "<group>"; };',
  );
  pbx.addObject(
    'PBXFileReference',
    '\t\t$plistRef /* Info.plist */ = {isa = PBXFileReference; '
        'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };',
  );
  pbx.addObject(
    'PBXFileReference',
    '\t\t$entRef /* $extName.entitlements */ = {isa = PBXFileReference; '
        'lastKnownFileType = text.plist.entitlements; path = $extName.entitlements; '
        'sourceTree = "<group>"; };',
  );
  pbx.addObject(
    'PBXBuildFile',
    '\t\t$swiftBuild /* DownloaderExtension.swift in Sources */ = '
        '{isa = PBXBuildFile; fileRef = $swiftRef /* DownloaderExtension.swift */; };',
  );
  pbx.addObject(
    'PBXBuildFile',
    '\t\t$embedBuild /* $extName.appex in Embed ExtensionKit Extensions */ = '
        '{isa = PBXBuildFile; fileRef = $product /* $extName.appex */; '
        'settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }; };',
  );

  pbx.addObject('PBXGroup', '''
\t\t$group /* $extName */ = {
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t$swiftRef /* DownloaderExtension.swift */,
\t\t\t\t$plistRef /* Info.plist */,
\t\t\t\t$entRef /* $extName.entitlements */,
\t\t\t);
\t\t\tpath = $extName;
\t\t\tsourceTree = "<group>";
\t\t};''');
  final project = pbx.requireObject(pbx.projectId, 'project');
  final mainGroup = PbxProject.field(project, 'mainGroup')!;
  pbx.addToList(mainGroup, 'children', ['$group /* $extName */']);
  final appProduct = PbxProject.field(
    pbx.requireObject(app, 'target'),
    'productReference',
  );
  for (final g in pbx.idsOf('PBXGroup')) {
    if (appProduct != null &&
        PbxProject.listIds(
          pbx.requireObject(g, 'group'),
          'children',
        ).contains(appProduct)) {
      pbx.addToList(g, 'children', ['$product /* $extName.appex */']);
      break;
    }
  }

  for (final (phaseId, isa, name, files) in [
    (
      sources,
      'PBXSourcesBuildPhase',
      'Sources',
      ['$swiftBuild /* DownloaderExtension.swift in Sources */'],
    ),
    (frameworks, 'PBXFrameworksBuildPhase', 'Frameworks', <String>[]),
    (resources, 'PBXResourcesBuildPhase', 'Resources', <String>[]),
  ]) {
    pbx.addObject(isa, '''
\t\t$phaseId /* $name */ = {
\t\t\tisa = $isa;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
${files.map((f) => '\t\t\t\t$f,\n').join()}\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};''');
  }

  pbx.addObject('PBXCopyFilesBuildPhase', '''
\t\t$embed /* Embed ExtensionKit Extensions */ = {
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "\$(EXTENSIONS_FOLDER_PATH)";
\t\t\tdstSubfolderSpec = 16;
\t\t\tfiles = (
\t\t\t\t$embedBuild /* $extName.appex in Embed ExtensionKit Extensions */,
\t\t\t);
\t\t\tname = "Embed ExtensionKit Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t};''');
  // Flutter's "Thin Binary" script must run after every embed phase, or Xcode
  // reports a dependency cycle; insert right after the Resources phase.
  final appResources = pbx.buildPhase(app, 'PBXResourcesBuildPhase');
  pbx.addToList(app, 'buildPhases', [
    '$embed /* Embed ExtensionKit Extensions */',
  ], after: appResources);

  pbx.addObject('PBXContainerItemProxy', '''
\t\t$proxy /* PBXContainerItemProxy */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = ${pbx.projectId} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = $target;
\t\t\tremoteInfo = $extName;
\t\t};''');
  pbx.addObject('PBXTargetDependency', '''
\t\t$dependency /* PBXTargetDependency */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = $target /* $extName */;
\t\t\ttargetProxy = $proxy /* PBXContainerItemProxy */;
\t\t};''');
  pbx.addToList(app, 'dependencies', ['$dependency /* PBXTargetDependency */']);

  pbx.addObject('PBXNativeTarget', '''
\t\t$target /* $extName */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = $configList /* Build configuration list for PBXNativeTarget "$extName" */;
\t\t\tbuildPhases = (
\t\t\t\t$sources /* Sources */,
\t\t\t\t$frameworks /* Frameworks */,
\t\t\t\t$resources /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = $extName;
\t\t\tproductName = $extName;
\t\t\tproductReference = $product /* $extName.appex */;
\t\t\tproductType = "com.apple.product-type.extensionkit-extension";
\t\t};''');
  pbx.addToList(pbx.projectId, 'targets', ['$target /* $extName */']);

  // One configuration per app configuration, with the same name, copying the
  // app's signing team so automatic signing works out of the box.
  final configIds = <String>[];
  for (final appConfig in appConfigs) {
    final body = pbx.requireObject(appConfig, 'build configuration');
    final name = PbxProject.field(body, 'name')!;
    final team = PbxProject.field(body, 'DEVELOPMENT_TEAM');
    final style = PbxProject.field(body, 'CODE_SIGN_STYLE');
    final cid = id('config:$name');
    configIds.add('$cid /* $name */');
    final debug = name.toLowerCase().contains('debug');
    pbx.addObject('XCBuildConfiguration', '''
\t\t$cid /* $name */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tCODE_SIGN_ENTITLEMENTS = $extName/$extName.entitlements;
${style == null ? '' : '\t\t\t\tCODE_SIGN_STYLE = $style;\n'}\t\t\t\tCURRENT_PROJECT_VERSION = 1;
${team == null ? '' : '\t\t\t\tDEVELOPMENT_TEAM = $team;\n'}\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_FILE = $extName/Info.plist;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = $extName;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 26.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"\$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t\t"@executable_path/../../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = ${PbxProject.quote('$bundleId.$extName')};
\t\t\t\tPRODUCT_NAME = "\$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSKIP_INSTALL = YES;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
${debug ? '\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n' : ''}\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t};
\t\t\tname = ${PbxProject.quote(name)};
\t\t};''');
  }
  pbx.addObject('XCConfigurationList', '''
\t\t$configList /* Build configuration list for PBXNativeTarget "$extName" */ = {
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
${configIds.map((c) => '\t\t\t\t$c,\n').join()}\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t};''');
}

String _entitlements(String group) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$group</string>
	</array>
</dict>
</plist>
''';

const _extensionInfoPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EXAppExtensionAttributes</key>
	<dict>
		<key>EXExtensionPointIdentifier</key>
		<string>com.apple.background-asset-downloader-extension</string>
	</dict>
</dict>
</plist>
''';

const _extensionSwift = '''
// Created by `dart run store_asset_packs:ios`. The system runs this extension
// to download Apple-hosted asset packs, including before the app's first
// launch. Edit it freely; the tool won't overwrite it.

import BackgroundAssets
import ExtensionFoundation
import StoreKit

@main
struct DownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        // Return false to skip a pack the system would otherwise download
        // automatically (essential and prefetch packs).
        return true
    }
}
''';

// ---------------------------------------------------------------------------
// Packaging

/// Builds each pack's Apple-hosted archive with `xcrun ba-package`, into
/// `build/store_asset_packs/ios/<pack>.aar`, for upload to App Store Connect.
/// The archive's root is a folder named after the pack, matching ODR and the
/// plugin's getPackPath.
Future<void> runIosPackage(ProjectConfig config, List<String> only) async {
  final packs = config.select(only);
  requireSources(packs);
  final out = Directory('${config.buildDir.path}/ios')
    ..createSync(recursive: true);
  for (final pack in packs) {
    final folder = pack.source.path.split('/').last;
    if (folder != pack.name) {
      throw ToolException(
        'Pack ${pack.name}: its folder must be named '
        '"${pack.name}" (it is "$folder").',
      );
    }
    final manifest = File('${out.path}/${pack.name}.json');
    manifest.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'assetPackID': pack.name,
        'downloadPolicy': {
          pack.iosDownloadPolicy: pack.iosDownloadPolicy == 'onDemand'
              ? <String, Object>{}
              : {
                  'installationEventTypes': [
                    'firstInstallation',
                    'subsequentUpdate',
                  ],
                },
        },
        'fileSelectors': [
          {'directory': pack.name},
        ],
        'platforms': ['iOS'],
      }),
    );
    final archive = File('${out.path}/${pack.name}.aar');
    if (archive.existsSync()) archive.deleteSync();
    await run('xcrun', [
      'ba-package',
      'package',
      manifest.path,
      '--output-path',
      archive.path,
      '--quiet',
    ], workingDirectory: pack.source.parent.path);
    final mb = (archive.lengthSync() / 1e6).toStringAsFixed(1);
    stdout.writeln(
      '${pack.name} (${pack.iosDownloadPolicy}): '
      '${relativePath(archive.path, config.root.path)} ($mb MB)',
    );
  }
  stdout.writeln(
    'Upload the .aar files to App Store Connect (Transporter or '
    'the App Store Connect API) for each app version that needs them.',
  );
}
