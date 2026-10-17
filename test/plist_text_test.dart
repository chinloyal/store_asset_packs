@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:store_asset_packs/src/tool/plist_text.dart';

const _info = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Export compliance: the app uses only exempt encryption. -->
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
	<key>SKAdNetworkItems</key>
	<array>
		<dict><key>SKAdNetworkIdentifier</key><string>cstr6suwn9.skadnetwork</string></dict>
		<dict><key>SKAdNetworkIdentifier</key><string>4fzdc2evr5.skadnetwork</string></dict>
	</array>
	<!-- <key>BAAppGroupID</key> in a comment must not count -->
	<key>UIRequiresFullScreen</key>
	<true/>
</dict>
</plist>
''';

const _entitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Game Center -->
	<key>com.apple.developer.game-center</key>
	<true/>
	<!-- Sign in with Apple -->
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
</dict>
</plist>
''';

void main() {
  test('appends new keys and leaves the rest byte for byte', () {
    final plist = PlistText(_info)
      ..set('BAHasManagedAssetPacks', '<true/>')
      ..set('BAAppGroupID', '<string>group.x</string>');
    expect(
      plist.text,
      _info.replaceFirst(
        '\t<true/>\n</dict>',
        '\t<true/>\n'
            '\t<key>BAHasManagedAssetPacks</key>\n\t<true/>\n'
            '\t<key>BAAppGroupID</key>\n\t<string>group.x</string>\n'
            '</dict>',
      ),
    );
  });

  test('replaces only the value of an existing key', () {
    final once = PlistText(_info)..set('BAAppGroupID', '<string>a</string>');
    final twice = PlistText(once.text)
      ..set('BAAppGroupID', '<string>b</string>');
    expect(
      twice.text,
      once.text.replaceFirst('<string>a</string>', '<string>b</string>'),
    );
    expect(twice.value('BAAppGroupID'), '<string>b</string>');
    // Setting the same value again changes nothing.
    final same = PlistText(twice.text)
      ..set('BAAppGroupID', '<string>b</string>');
    expect(same.text, twice.text);
  });

  test('reads top-level values only, ignoring comments and nested keys', () {
    final plist = PlistText(_info);
    expect(plist.value('UIRequiresFullScreen'), '<true/>');
    expect(plist.value('SKAdNetworkIdentifier'), isNull);
    expect(plist.value('BAAppGroupID'), isNull);
    expect(plist.value('SKAdNetworkItems'), startsWith('<array>'));
  });

  test('creates the app-groups array in a file with comments', () {
    final plist = PlistText(_entitlements)
      ..addString('com.apple.security.application-groups', 'group.com.example');
    expect(
      plist.text,
      _entitlements.replaceFirst(
        '\t</array>\n</dict>',
        '\t</array>\n'
            '\t<key>com.apple.security.application-groups</key>\n'
            '\t<array>\n\t\t<string>group.com.example</string>\n\t</array>\n'
            '</dict>',
      ),
    );
    // Adding it again changes nothing.
    final again = PlistText(plist.text)
      ..addString('com.apple.security.application-groups', 'group.com.example');
    expect(again.text, plist.text);
  });

  test('adds to an existing array', () {
    final plist = PlistText(_entitlements)
      ..addString('com.apple.developer.applesignin', 'Other');
    expect(
      plist.text,
      _entitlements.replaceFirst(
        '\t\t<string>Default</string>\n',
        '\t\t<string>Default</string>\n\t\t<string>Other</string>\n',
      ),
    );
  });

  test('fills an empty array', () {
    final plist = PlistText(
      _entitlements.replaceFirst(
        '<array>\n\t\t<string>Default</string>\n\t</array>',
        '<array/>',
      ),
    )..addString('com.apple.developer.applesignin', 'Default');
    expect(plist.text, _entitlements);
  });
}
