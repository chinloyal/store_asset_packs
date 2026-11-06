## 1.0.0

* iOS: nothing waits on Background Assets for ever. An app on iOS 26+ could
  sit on "pending" until it was reinstalled (App Review saw it too):
  * looking a pack up on Apple's servers now times out after 15 seconds,
    and packs are looked up at the same time rather than one after another;
    a pack that can't be looked up is served by On-Demand Resources;
  * the 20-second fallback decides from what Background Assets has
    reported, rather than asking it again (the question could hang just
    like the request);
  * a pack Background Assets started but then stopped moving for 45 seconds
    (paused, or gone quiet) falls back to On-Demand Resources too;
  * a pack Background Assets calls complete but has no folder for is
    fetched from On-Demand Resources;
  * `fetch` reports a pack that's already on the device as `completed`.
* iOS: On-Demand Resources requests made by `fetch` are urgent.

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
