import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'asset_pack_state.dart';

/// Store-delivered asset packs: Play Asset Delivery on Android, Background
/// Assets (iOS 26+, Apple-hosted packs) or On-Demand Resources (iOS 15–25)
/// on iOS.
///
/// A pack is a folder of files. Once it is [AssetPackStatus.completed],
/// [getPackPath] returns an absolute directory path, and the pack's files sit
/// under it at their paths relative to the pack's source folder.
///
/// In debug builds, a pack copied to the dev-override directory with
/// `dart run store_asset_packs:push` counts as completed and is read from
/// there, because the stores never deliver packs to a `flutter run` install.
abstract final class StoreAssetPacks {
  static const MethodChannel _channel = MethodChannel('store_asset_packs');
  static const EventChannel _events = EventChannel('store_asset_packs/updates');

  /// Whether the dev override applies. True in debug builds.
  @visibleForTesting
  static bool devOverrideEnabled = kDebugMode;

  static String? _devRoot;
  static StreamController<AssetPackState>? _updates;
  static StreamSubscription<Object?>? _platformUpdates;

  /// The name of the directory, inside the app's files directory (Android)
  /// or Documents directory (iOS), that holds dev-override packs.
  static const String devOverrideDirectoryName = 'store_asset_packs_dev';

  /// The current state of each of [packs], keyed by pack name. Every pack
  /// asked about gets an entry. A store error (for example Play's -1 for an
  /// app that wasn't installed from Play) is reported per pack as
  /// [AssetPackStatus.failed] with [AssetPackState.errorCode] rather than
  /// thrown.
  static Future<Map<String, AssetPackState>> getStates(
    List<String> packs,
  ) async {
    final result = <String, AssetPackState>{};
    final remote = <String>[];
    for (final pack in packs) {
      if (await _devPackPath(pack) != null) {
        result[pack] = _devState(pack);
      } else {
        remote.add(pack);
      }
    }
    if (remote.isNotEmpty) {
      final states = await _channel.invokeMapMethod<String, Object?>(
        'getStates',
        {'packs': remote},
      );
      for (final pack in remote) {
        final state = states?[pack];
        result[pack] = state is Map
            ? AssetPackState.fromMap(state)
            : AssetPackState(name: pack, status: AssetPackStatus.unknown);
      }
    }
    return result;
  }

  /// Starts downloading [packs]. Packs already on the device are left alone,
  /// so this is safe to call on every launch. Progress arrives on [updates].
  ///
  /// Completes once the request is made, not when the downloads finish.
  static Future<void> fetch(List<String> packs) async {
    final remote = <String>[];
    for (final pack in packs) {
      if (await _devPackPath(pack) != null) {
        _controller.add(_devState(pack));
      } else {
        remote.add(pack);
      }
    }
    if (remote.isEmpty) return;
    await _channel.invokeMethod<void>('fetch', {'packs': remote});
  }

  /// State changes for every pack, as they happen. A broadcast stream.
  static Stream<AssetPackState> get updates => _controller.stream;

  /// The absolute path of the directory holding [pack]'s files, or null
  /// until the pack is available.
  ///
  /// On iOS with On-Demand Resources, this begins access to the pack's tag,
  /// and the files stay on the device until [release].
  static Future<String?> getPackPath(String pack) async {
    final dev = await _devPackPath(pack);
    if (dev != null) return dev;
    return _channel.invokeMethod<String>('getPackPath', {'pack': pack});
  }

  /// Shows Play's dialog asking the player to allow the download over mobile
  /// data, or to confirm it, when a pack is [AssetPackStatus.waitingForWifi]
  /// or [AssetPackStatus.requiresUserConfirmation]. Returns whether the
  /// player agreed. Always true on iOS.
  static Future<bool> showCellularDataConfirmation() async {
    final ok = await _channel.invokeMethod<bool>(
      'showCellularDataConfirmation',
    );
    return ok ?? false;
  }

  /// Tells the system the app is done with [pack] for now. On iOS with
  /// On-Demand Resources this ends access, so the system may purge the files
  /// when it needs space; elsewhere it does nothing.
  static Future<void> release(String pack) async {
    if (await _devPackPath(pack) != null) return;
    await _channel.invokeMethod<void>('release', {'pack': pack});
  }

  /// The dev-override directory for this app install: copy a pack's files to
  /// `<this>/<pack>/` to have debug builds treat it as installed.
  static Future<String?> getDevOverrideDirectory() async =>
      _devRoot ??= await _channel.invokeMethod<String>('getDevOverrideRoot');

  static StreamController<AssetPackState> get _controller =>
      _updates ??= StreamController<AssetPackState>.broadcast(
        onListen: () {
          _platformUpdates = _events.receiveBroadcastStream().listen(
            (event) {
              if (event is Map) {
                _updates?.add(AssetPackState.fromMap(event));
              }
            },
            onError: (Object error, StackTrace stack) =>
                _updates?.addError(error, stack),
          );
        },
        onCancel: () {
          _platformUpdates?.cancel();
          _platformUpdates = null;
        },
      );

  static Future<String?> _devPackPath(String pack) async {
    if (!devOverrideEnabled) return null;
    final root = await getDevOverrideDirectory();
    if (root == null) return null;
    final dir = Directory('$root/$pack');
    try {
      return await dir.exists() ? dir.path : null;
    } on FileSystemException {
      // Unreadable (e.g. created by adb before the app was installed).
      return null;
    }
  }

  static AssetPackState _devState(String pack) => AssetPackState(
    name: pack,
    status: AssetPackStatus.completed,
    progress: 1,
  );

  /// Forgets cached state, for tests.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _platformUpdates?.cancel();
    _platformUpdates = null;
    await _updates?.close();
    _updates = null;
    _devRoot = null;
    devOverrideEnabled = kDebugMode;
  }
}
