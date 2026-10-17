// Created by `dart run store_asset_packs:ios`. The system runs this extension
// to download Apple-hosted asset packs, including before the app's first
// launch. Edit it freely; the tool won't overwrite it.

import BackgroundAssets
import ExtensionFoundation
import StoreKit

@main
struct DownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        // Return false to skip a pack the system would otherwise download
        // automatically (essential and prefetch packs).
        return true
    }
}
