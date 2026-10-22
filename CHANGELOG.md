## Unreleased

* iOS: a pack that Background Assets doesn't start downloading within 20
  seconds now falls back to On-Demand Resources, like after a failure. Before,
  a request that was accepted but never started (seen on iOS 27) left the pack
  pending forever.

## 0.1.0

* First version: `StoreAssetPacks` (getStates, fetch, updates, getPackPath,
  showCellularDataConfirmation, release) over Play Asset Delivery, Background
  Assets (iOS 26+, with ODR fallback) and On-Demand Resources.
* Debug dev override (`store_asset_packs_dev`).
* Tools: `dart run store_asset_packs:android`, `:ios` (odr, background-assets,
  package) and `:push`.
