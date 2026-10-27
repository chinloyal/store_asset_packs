## 0.1.0

* First version: `StoreAssetPacks` (getStates, fetch, updates, getPackPath,
  showCellularDataConfirmation, release) over Play Asset Delivery, Background
  Assets (iOS 26+, with ODR fallback) and On-Demand Resources.
* iOS: a pack that Background Assets doesn't start downloading within 20
  seconds falls back to On-Demand Resources, like after a failure, so a
  request that is accepted but never started (seen on iOS 27) doesn't leave
  the pack pending forever.
* Debug dev override (`store_asset_packs_dev`).
* Tools: `dart run store_asset_packs:android`, `:ios` (odr, background-assets,
  package) and `:push`.
