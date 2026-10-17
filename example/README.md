# store_asset_packs example

Two packs, `packs/fast_pack` (fast-follow) and `packs/ondemand_pack`
(on-demand), declared in `pubspec.yaml` and wired in with:

```bash
dart run store_asset_packs:android
dart run store_asset_packs:ios
```

- Android: build an app bundle and install it with
  `bundletool ... --local-testing` (see the package README), then tap Fetch.
- iOS: `flutter run` on a simulator; Debug embeds the ODR packs.
- Any debug build: `dart run store_asset_packs:push` to skip the store.
- `flutter test integration_test -d <device>` runs the whole flow.
