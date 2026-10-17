import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:store_asset_packs/store_asset_packs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('store_asset_packs');
  const events = EventChannel('store_asset_packs/updates');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Directory devRoot;
  Map<String, Object?> nativeStates = {};
  String? nativePath;

  setUp(() async {
    calls = [];
    devRoot = await Directory.systemTemp.createTemp('store_asset_packs_test');
    nativeStates = {};
    nativePath = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getDevOverrideRoot':
          return devRoot.path;
        case 'getStates':
          final packs = (call.arguments as Map)['packs'] as List;
          return {
            for (final p in packs)
              if (nativeStates.containsKey(p)) p: nativeStates[p],
          };
        case 'getPackPath':
          return nativePath;
        case 'showCellularDataConfirmation':
          return true;
        case 'fetch':
        case 'release':
          return null;
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(events, null);
    await StoreAssetPacks.resetForTesting();
    await devRoot.delete(recursive: true);
  });

  List<String> methods() => calls
      .map((c) => c.method)
      .where((m) => m != 'getDevOverrideRoot')
      .toList();

  group('AssetPackState', () {
    test('decodes every status name', () {
      for (final status in AssetPackStatus.values) {
        final state = AssetPackState.fromMap({
          'name': 'p',
          'status': status.name,
        });
        expect(state.status, status);
      }
    });

    test('unknown status names become unknown', () {
      final state = AssetPackState.fromMap({'name': 'p', 'status': 'weird'});
      expect(state.status, AssetPackStatus.unknown);
    });

    test('decodes numbers and errors', () {
      final state = AssetPackState.fromMap({
        'name': 'chapter2',
        'status': 'failed',
        'bytesDownloaded': 5,
        'totalBytes': 10,
        'progress': 0.5,
        'errorCode': -6,
        'errorMessage': 'network',
      });
      expect(state.bytesDownloaded, 5);
      expect(state.totalBytes, 10);
      expect(state.progress, 0.5);
      expect(state.errorCode, -6);
      expect(state.errorMessage, 'network');
      expect(state.isAvailable, isFalse);
      expect(AssetPackState.fromMap(state.toMap()), state);
    });

    test('clamps progress', () {
      final state = AssetPackState.fromMap({
        'name': 'p',
        'status': 'downloading',
        'progress': 1.7,
      });
      expect(state.progress, 1);
    });
  });

  group('with the dev override off', () {
    setUp(() => StoreAssetPacks.devOverrideEnabled = false);

    test('getStates asks the platform and fills in missing packs', () async {
      nativeStates = {
        'a': {'name': 'a', 'status': 'completed', 'progress': 1.0},
      };
      final states = await StoreAssetPacks.getStates(['a', 'b']);
      expect(states['a']!.status, AssetPackStatus.completed);
      expect(states['b']!.status, AssetPackStatus.unknown);
      expect(calls.single.arguments, {
        'packs': ['a', 'b'],
      });
    });

    test('fetch, getPackPath and release call through', () async {
      nativePath = '/data/packs/a/assets';
      await StoreAssetPacks.fetch(['a']);
      expect(await StoreAssetPacks.getPackPath('a'), '/data/packs/a/assets');
      await StoreAssetPacks.release('a');
      expect(methods(), ['fetch', 'getPackPath', 'release']);
      expect(calls[0].arguments, {
        'packs': ['a'],
      });
      expect(calls[1].arguments, {'pack': 'a'});
    });

    test('ignores a dev-override folder', () async {
      await Directory('${devRoot.path}/a').create();
      expect(await StoreAssetPacks.getPackPath('a'), isNull);
    });

    test('showCellularDataConfirmation returns the platform answer', () async {
      expect(await StoreAssetPacks.showCellularDataConfirmation(), isTrue);
    });

    test('updates decodes platform events', () async {
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (args, sink) {
            sink.success({
              'name': 'a',
              'status': 'waitingForWifi',
              'bytesDownloaded': 0,
              'totalBytes': 100,
            });
            sink.success({
              'name': 'a',
              'status': 'requiresUserConfirmation',
              'totalBytes': 100,
            });
          },
        ),
      );
      final got = await StoreAssetPacks.updates.take(2).toList();
      expect(got.map((s) => s.status), [
        AssetPackStatus.waitingForWifi,
        AssetPackStatus.requiresUserConfirmation,
      ]);
      expect(got.first.totalBytes, 100);
    });
  });

  group('with the dev override on', () {
    setUp(() async {
      StoreAssetPacks.devOverrideEnabled = true;
      await Directory('${devRoot.path}/dev').create();
    });

    test('a dev pack is completed and skips the platform', () async {
      nativeStates = {
        'store': {'name': 'store', 'status': 'notInstalled'},
      };
      final states = await StoreAssetPacks.getStates(['dev', 'store']);
      expect(states['dev']!.status, AssetPackStatus.completed);
      expect(states['dev']!.progress, 1);
      expect(states['store']!.status, AssetPackStatus.notInstalled);
      expect(calls.last.arguments, {
        'packs': ['store'],
      });
    });

    test('getPackPath returns the dev folder', () async {
      expect(await StoreAssetPacks.getPackPath('dev'), '${devRoot.path}/dev');
      expect(methods(), isEmpty);
    });

    test('getPackPath falls back to the platform', () async {
      nativePath = '/bundle/store';
      expect(await StoreAssetPacks.getPackPath('store'), '/bundle/store');
    });

    test('fetch reports dev packs as completed without the platform', () async {
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(onListen: (args, sink) {}),
      );
      final next = StoreAssetPacks.updates.first;
      await StoreAssetPacks.fetch(['dev']);
      final state = await next.timeout(const Duration(seconds: 1));
      expect(state.name, 'dev');
      expect(state.status, AssetPackStatus.completed);
      expect(methods(), isEmpty);
    });

    test('fetch sends only store packs', () async {
      await StoreAssetPacks.fetch(['dev', 'store']);
      expect(methods(), ['fetch']);
      expect(calls.last.arguments, {
        'packs': ['store'],
      });
    });

    test('release skips dev packs', () async {
      await StoreAssetPacks.release('dev');
      expect(methods(), isEmpty);
    });
  });
}
