// Runs against the real store backend of the device it's on:
//   flutter test integration_test -d <simulator>
// iOS: the example's Debug configuration embeds its ODR packs (set up by
// `dart run store_asset_packs:ios odr`), so the simulator serves them
// locally. Don't `push` packs first: dev-override packs skip the store.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:store_asset_packs/store_asset_packs.dart';

const packs = ['fast_pack', 'ondemand_pack'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fetches packs and reads their files', (tester) async {
    final updates = <AssetPackState>[];
    final sub = StoreAssetPacks.updates.listen(updates.add);
    addTearDown(sub.cancel);

    final before = await StoreAssetPacks.getStates(packs);
    for (final pack in packs) {
      expect(before[pack], isNotNull, reason: pack);
      // ignore: avoid_print
      print('before: ${before[pack]}');
    }

    final completed = Completer<void>();
    final done = <String>{
      for (final s in before.values)
        if (s.isAvailable) s.name,
    };
    if (done.length == packs.length) completed.complete();
    final watch = StoreAssetPacks.updates.listen((s) {
      if (s.status == AssetPackStatus.completed) done.add(s.name);
      if (s.status == AssetPackStatus.failed) {
        completed.completeError(
          '${s.name} failed: ${s.errorCode} ${s.errorMessage}',
        );
      }
      if (done.length == packs.length && !completed.isCompleted) {
        completed.complete();
      }
    });
    addTearDown(watch.cancel);

    await StoreAssetPacks.fetch(packs);
    await completed.future.timeout(const Duration(seconds: 60));

    final after = await StoreAssetPacks.getStates(packs);
    for (final pack in packs) {
      expect(after[pack]!.status, AssetPackStatus.completed, reason: pack);
      final path = await StoreAssetPacks.getPackPath(pack);
      // ignore: avoid_print
      print('path $pack: $path');
      expect(path, isNotNull, reason: pack);
      expect(File('$path/image.png').existsSync(), isTrue, reason: pack);
      expect(File('$path/nested/image.png').existsSync(), isTrue, reason: pack);
    }
    // ignore: avoid_print
    print(
      'updates: ${updates.map((u) => '${u.name}:${u.status.name}').join(' ')}',
    );

    for (final pack in packs) {
      await StoreAssetPacks.release(pack);
    }
  });
}
