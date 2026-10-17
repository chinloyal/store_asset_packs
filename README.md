# store_asset_packs

Store-delivered asset packs for Flutter apps, with one API and identical
statuses on both platforms:

| Platform | Delivery |
|---|---|
| Android | [Play Asset Delivery](https://developer.android.com/guide/playcore/asset-delivery): fast-follow and on-demand packs |
| iOS 26+ | [Background Assets](https://developer.apple.com/documentation/backgroundassets) with Apple-hosted asset packs, falling back to On-Demand Resources |
| iOS 15–25 | [On-Demand Resources](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/On_Demand_Resources_Guide/) |

A pack is a plain folder in your project, for example `assets/levels/world2/`.
The same folder feeds every store, and nothing is re-encoded: once the pack is
on the device, `getPackPath` returns an absolute directory, and the files sit
under it at their paths relative to the folder.

The package also ships command-line tools that wire the packs into your
Gradle and Xcode projects, build the Apple-hosted archives, and copy packs
onto a device for `flutter run`.

- [Dart API](#dart-api)
- [Setup](#setup)
- [Local testing](#local-testing)
- [Store limits](#store-limits)
- [How it works](#how-it-works)

## Dart API

```dart
import 'package:store_asset_packs/store_asset_packs.dart';

const packs = ['world2', 'world3'];

final states = await StoreAssetPacks.getStates(packs);   // Map<String, AssetPackState>
StoreAssetPacks.updates.listen((s) async {                // every pack, one stream
  if (s.status == AssetPackStatus.waitingForWifi ||
      s.status == AssetPackStatus.requiresUserConfirmation) {
    await StoreAssetPacks.showCellularDataConfirmation();  // Play's dialog; true on iOS
  }
});
await StoreAssetPacks.fetch(packs);                       // no-op for packs already on the device

final dir = await StoreAssetPacks.getPackPath('world2');  // null until available
final map = File('$dir/map_0.png');
```

| Member | Notes |
|---|---|
| `Future<Map<String, AssetPackState>> getStates(List<String> packs)` | One entry per pack asked about. Store errors (for example Play's `-1` for an app not installed from Play) come back as `failed` with `errorCode` instead of being thrown. |
| `Future<void> fetch(List<String> packs)` | Starts downloads and returns once they're requested. Progress arrives on `updates`. |
| `Stream<AssetPackState> get updates` | Broadcast stream for every pack. |
| `Future<String?> getPackPath(String pack)` | Absolute directory path (not a URL), or null until the pack is `completed`. On iOS ODR this begins access to the tag, which lasts until `release`. |
| `Future<bool> showCellularDataConfirmation()` | Android: Play's confirmation dialog (`showConfirmationDialog`); returns whether the player agreed. iOS: `true`. |
| `Future<void> release(String pack)` | iOS ODR: ends access so iOS may purge the pack when it needs space. Does nothing elsewhere. |
| `Future<String?> getDevOverrideDirectory()` | Where debug builds look for pushed packs. |

`AssetPackState` has `name`, `status`, `bytesDownloaded`, `totalBytes`,
`progress` (0–1), `errorCode` and `errorMessage`.

`AssetPackStatus` values: `notInstalled`, `pending`, `downloading`, `transferring`,
`waitingForWifi`, `requiresUserConfirmation`, `completed`, `failed`, `canceled`,
`unknown`. Android maps Play's `AssetPackStatus` one to one. iOS uses
`notInstalled`, `pending`, `downloading`, `completed`, `failed` and `canceled`.
ODR reports progress but no byte counts.

`errorCode` is Play's [`AssetPackErrorCode`](https://developer.android.com/reference/com/google/android/play/core/assetpacks/model/AssetPackErrorCode)
on Android (for example `-6` network error, `-10` insufficient storage) and the
`NSError` code on iOS.

### Debug builds: the dev override

The stores never deliver packs to a `flutter run` install. So in debug builds
(`kDebugMode`), a pack folder at `<dev dir>/<pack>/` counts as installed:
`getStates` reports it as `completed`, `fetch` emits `completed` without
calling the store, and `getPackPath` returns that folder. The dev directory is:

- Android: `<external files dir>/store_asset_packs_dev`, i.e.
  `/sdcard/Android/data/<applicationId>/files/store_asset_packs_dev` (or
  `filesDir` if there's no external storage)
- iOS: `<Documents>/store_asset_packs_dev`

`dart run store_asset_packs:push` fills it (see [push](#push-packs-onto-a-debug-install)).
Release and profile builds ignore it.

## Setup

### 1. Declare the packs

Add a `store_asset_packs:` section to your app's `pubspec.yaml` (or put the same
keys in `store_asset_packs.yaml`):

```yaml
store_asset_packs:
  packs:
    world2: assets/levels/world2          # pack name → source folder
    world3:
      source: assets/levels/world3
      android_delivery_type: on-demand    # per-pack override
      ios_download_policy: onDemand       # per-pack override
  android:
    delivery_type: fast-follow            # install-time | fast-follow (default) | on-demand
  ios:
    download_policy: prefetch             # essential | prefetch (default) | onDemand
    background_assets: true               # also set up Apple-hosted Background Assets
    # target: Runner                      # app target (default Runner)
    # app_group: group.com.example.game   # default group.<bundle id>
    # extension_name: AssetPackDownloader
```

Rules:

- Pack names start with a letter and use only letters, digits and `_`.
- Each source folder must be named after its pack (`.../world2/` for
  `world2`). An iOS folder reference keeps its folder name in the bundle.
- **Don't list the pack folders under `flutter: assets:`.** That would ship
  them inside the app. The tools read the folders straight from disk.

Run the tools from the app's root. If you use fvm, run `fvm dart run …`.

### 2. Android

```bash
dart run store_asset_packs:android
```

For each pack, this:

- writes `android/<pack>/build.gradle.kts` (plugin `com.android.asset-pack`,
  `packName`, `deliveryType`) and a `.gitignore`;
- adds `include(":<pack>", …)` to `android/settings.gradle.kts`;
- adds `assetPacks += listOf(":<pack>", …)` to `android/app/build.gradle.kts`.

Both edits sit between `// store_asset_packs: begin/end` markers. Run the
command again whenever the packs change. `--check` exits with status 1 if
anything is out of date, which is useful in CI.

Only the Kotlin DSL (`.kts`) is supported. Files aren't copied into git: a
`syncPackAssets` Gradle task copies each source folder into the module's
gitignored `src/main/assets/<pack>/` before every build. They go under a
`<pack>/` folder because Play requires every asset path to be unique across
all packs.

Notes:

- `getPackPath` only works for **fast-follow** and **on-demand** packs, which
  Play stores as files. Install-time packs live inside the APK
  (`AssetManager`), so `getPackPath` returns null for them.
- Fast-follow packs start downloading right after the install, but call `fetch`
  anyway as a fallback. It's a no-op for packs that are already there, and it
  covers packs that were evicted or whose download failed.
- The Play library merges the `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_DATA_SYNC` permissions into your manifest. With
  targetSdk 34+, the Play Console asks you to declare that foreground service
  use (Play's pack extraction service).
- The plugin ships consumer R8 rules for two release-build problems in the
  Play library under AGP 9: a missing annotation class, and WorkManager's Room
  database being stripped, which crashes the app at startup.
- Tested with AGP 9.0.1, Kotlin 2.3.20, Gradle 9.1.0, JDK 17, minSdk 24, and
  `android.newDsl=false` / `android.builtInKotlin=false`.

### 3. iOS

The plugin needs iOS 15 and supports Swift Package Manager (CocoaPods works
too).

```bash
dart run store_asset_packs:ios                    # odr, plus background-assets when ios.background_assets is true
dart run store_asset_packs:ios odr                # On-Demand Resources only
dart run store_asset_packs:ios background-assets  # Background Assets only
dart run store_asset_packs:ios package            # build the Apple-hosted archives
```

All of these accept `--check`.

**`odr`** edits `ios/Runner.xcodeproj`:

- adds each source folder as a **folder reference** in a `StoreAssetPacks`
  group, tagged with the pack's name (`ASSET_TAGS`), in the app target's
  Resources phase;
- adds the tags to the project's `knownAssetTags`;
- maps `essential` packs to `ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS` and
  `prefetch` packs to `ON_DEMAND_RESOURCES_PREFETCH_ORDER`;
- sets `EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE = YES` on Debug configurations, so
  `flutter run` installs carry the packs and iOS serves them locally. Release
  builds leave them out for the App Store to host.

Every object the tool adds has a deterministic ID starting with `5A55E7`, so
reruns replace its own entries and leave everything else alone.

**`background-assets`** sets up Apple-hosted packs:

- adds `BAHasManagedAssetPacks`, `BAUsesAppleHosting` and `BAAppGroupID` to
  `ios/Runner/Info.plist`;
- adds the app group to the app's entitlements, reusing
  `CODE_SIGN_ENTITLEMENTS` if it's set and creating `Runner/Runner.entitlements`
  if not;
- creates the downloader extension (`ios/AssetPackDownloader/`, a
  `StoreDownloaderExtension`, as in Xcode's "Background Download Extension,
  Apple-Hosted, Managed" template) and its target. The target has an iOS 26
  minimum, bundle id `<app>.AssetPackDownloader`, and copies the app's
  `DEVELOPMENT_TEAM` and `CODE_SIGN_STYLE`. It's embedded before Flutter's
  "Thin Binary" phase.

The tool creates the target once and leaves it alone on later runs, so your
own signing changes survive. Register the app group for both bundle ids in the
Apple Developer portal, or let automatic signing do it. If you sign manually,
the extension needs its own provisioning profile.

**`package`** runs `xcrun ba-package` for each pack and writes
`build/store_asset_packs/ios/<pack>.aar` and its manifest. Each archive's root
is a folder named after the pack, so the layout matches ODR. Upload the
archives to App Store Connect (Transporter or the App Store Connect API) for
each version that needs them, then attach them to the build.

At runtime the plugin picks the backend from Info.plist. On iOS 26+ with
`BAHasManagedAssetPacks` and `BAUsesAppleHosting`, it uses Background Assets.
For any pack Background Assets can't deliver, it **falls back to ODR**: App
Review disables Apple-hosted pre-launch downloads, and unsigned or development
builds get "No team ID was specified". That's why `odr` should always run, and
why ODR stays in the build even when you use Background Assets. Otherwise
(below iOS 26, or without those keys) it uses ODR.

Apple has deprecated ODR as of iOS 27. ODR keeps working where it exists, and
Background Assets is the path forward.

### Push packs onto a debug install

```bash
dart run store_asset_packs:push                  # the only connected device/simulator
dart run store_asset_packs:push -d emulator-5554 # adb serial, or a simulator UDID or name
dart run store_asset_packs:push --pack world2    # only some packs
dart run store_asset_packs:push --remove         # delete them again, to test real delivery
```

This copies only what changed: `adb push --sync` on Android, and `rsync` into
the app container from `xcrun simctl get_app_container` on simulators.

- Install and run the app once first. Otherwise Android creates the folder as
  the shell user and the app can't read it.
- It reads the applicationId and bundle id from the project; `--app-id`
  overrides them.
- Physical iPhones aren't supported.

## Local testing

### Android: bundletool local testing

```bash
flutter build appbundle --release
bundletool build-apks --bundle=build/app/outputs/bundle/release/app-release.aab \
  --output=build/local.apks --local-testing
bundletool install-apks --apks=build/local.apks
```

With `--local-testing`, the packs are pushed to the device, and the Play
library "downloads" them from there, so the real pending → downloading →
transferring → completed flow runs. Fast-follow packs behave like on-demand
ones in local testing: they arrive only when you call `fetch`. Play's
confirmation dialogs never appear locally; use an internal testing track to
see them.

### iOS: On-Demand Resources

Run the app from Xcode or with `flutter run` (Debug embeds the packs). Don't
`push` packs first, or the dev override will short-circuit the store. On the
simulator, both iOS 26 (through the fallback) and earlier versions use ODR.

### iOS: Background Assets

Background Assets needs a build signed with your team. Then either:

- **TestFlight:** upload the `.aar` archives from `ios package` for the build's
  version, or
- **Apple's mock server:** `xcrun ba-serve serve build/store_asset_packs/ios/*.aar --host <your Mac's hostname>`.
  It needs a TLS server identity for that host in your keychain that the
  device trusts. Point the device at the server with
  `ba-serve url-override https://<host>:<port>` on the device, or with the
  Background Assets override in the device's Developer settings.

### The example app

`example/` has two packs (`fast_pack` fast-follow, `ondemand_pack` on-demand)
and an integration test that runs the whole flow against the real store
backend: `flutter test integration_test -d <device>`.

## Store limits

All figures are current as of October 2026; check the linked pages for changes.

**Google Play** ([size limits](https://support.google.com/googleplay/android-developer/answer/9859372#size_limits), compressed download):

- each asset pack: 1.5 GB;
- fast-follow and on-demand packs together: 30 GB;
- base, feature modules and install-time packs together: 4 GB;
- at most 100 asset packs per bundle; 34 GB per app in total;
- apps over 200 MB show players on mobile data a download warning. Downloads
  can also stop at `waitingForWifi` or `requiresUserConfirmation`. Watch for
  both and call `showCellularDataConfirmation()`.

**Apple-hosted asset packs** ([limits](https://developer.apple.com/help/app-store-connect/reference/app-uploads/apple-hosted-asset-pack-size-limits)):
200 GB and 200 packs per app record, shared across platforms.

**On-Demand Resources** ([limits](https://developer.apple.com/help/app-store-connect/reference/app-uploads/on-demand-resources-size-limits)):

| | Before iOS 18 | iOS 18+ |
|---|---|---|
| Per asset pack | 512 MB | 8 GB |
| Initial install + prefetched tags | 4 GB | no limit |
| In use at once | 2 GB | no limit |
| Hosted in total | 20 GB | 70 GB |

## How it works

- **Android:** `com.google.android.play:asset-delivery-ktx` 2.3.0
  (`AssetPackManager`: `requestPackStates`, `requestFetch`, a state listener
  for `updates`, `showConfirmationDialog(activity)` and `getPackLocation`).
  `getPackPath` returns `<assetsPath>/<pack>` for packs stored as files.
- **iOS ODR:** one `NSBundleResourceRequest` per tag.
  `conditionallyBeginAccessingResources` checks whether a pack is present, and
  `beginAccessingResources` downloads it. The request is kept while the pack
  is in use, and the path is the folder reference's URL in the bundle.
- **iOS Background Assets:** `AssetPackManager.shared`. `statusUpdates` feeds
  `updates`, `ensureLocalAvailability` downloads, and the path is
  `url(for: "<pack>")`. BackgroundAssets is weak-linked, so the app still runs
  on iOS 15.
