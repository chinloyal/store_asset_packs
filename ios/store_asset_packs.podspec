#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint store_asset_packs.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'store_asset_packs'
  s.version          = '0.1.0'
  s.summary          = 'Store-delivered asset packs: Background Assets and On-Demand Resources.'
  s.description      = <<-DESC
Store-delivered asset packs for Flutter: Background Assets (iOS 26+) and On-Demand Resources.
                       DESC
  s.homepage         = 'https://github.com/chinloyal/store_asset_packs'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'chinloyal' => 'chinloy@potudo.com' }
  s.source           = { :path => '.' }
  s.source_files = 'store_asset_packs/Sources/store_asset_packs/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.weak_frameworks = 'BackgroundAssets'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  s.resource_bundles = {'store_asset_packs_privacy' => ['store_asset_packs/Sources/store_asset_packs/PrivacyInfo.xcprivacy']}
end
