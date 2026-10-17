import Foundation

#if canImport(BackgroundAssets)
  import BackgroundAssets
  import System

  /// Background Assets with Apple-hosted asset packs (iOS 26+). Each pack's
  /// archive holds a single root folder named after the pack (see
  /// `dart run store_asset_packs:ios package`), so the pack's directory is
  /// `url(for: "<pack>")`.
  @available(iOS 26.0, *)
  final class BackgroundAssetsBackend: PackBackend {
    var onUpdate: ((PackState) -> Void)?

    private let manager = AssetPackManager.shared
    private let lock = NSLock()
    private var last: [String: PackState] = [:]
    private var sizes: [String: Int64] = [:]
    private var observer: Task<Void, Never>?

    init() {
      observer = Task { [weak self] in
        guard let manager = self?.manager else { return }
        for await update in await manager.statusUpdates {
          self?.handle(update)
        }
      }
    }

    deinit { observer?.cancel() }

    private func locked<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }

    private func report(_ state: PackState) {
      let name = state["name"] as! String
      locked { last[name] = state }
      onUpdate?(state)
    }

    private func handle(_ update: AssetPackManager.DownloadStatusUpdate) {
      switch update {
      case .began(let pack):
        remember(pack)
        report(packState(pack.id, "downloading", totalBytes: Int64(pack.downloadSize)))
      case .paused(let pack):
        let previous = locked { last[pack.id] }
        report(
          packState(
            pack.id, "pending", progress: previous?["progress"] as? Double ?? 0,
            bytesDownloaded: previous?["bytesDownloaded"] as? Int64 ?? 0,
            totalBytes: Int64(pack.downloadSize)))
      case .downloading(let pack, let progress):
        let total = Int64(pack.downloadSize)
        let fraction = progress.fractionCompleted
        let previous = locked { last[pack.id]?["progress"] as? Double ?? 0 }
        if fraction < 1, fraction - previous < 0.01, locked({ last[pack.id] }) != nil { return }
        report(
          packState(
            pack.id, "downloading", progress: fraction,
            bytesDownloaded: Int64(Double(total) * fraction), totalBytes: total))
      case .finished(let pack):
        let total = Int64(pack.downloadSize)
        report(packState(pack.id, "completed", bytesDownloaded: total, totalBytes: total))
      case .failed(let pack, let error):
        report(packState(pack.id, "failed", totalBytes: Int64(pack.downloadSize), error: error))
      @unknown default:
        break
      }
    }

    private func remember(_ pack: AssetPack) {
      locked { sizes[pack.id] = Int64(pack.downloadSize) }
    }

    private func isAvailable(_ id: String) async -> Bool {
      if #available(iOS 26.4, *) {
        return manager.assetPackIsAvailableLocally(withID: id)
      }
      let status = try? await manager.status(ofAssetPackWithID: id)
      return status?.contains(.downloaded) ?? false
    }

    func states(_ packs: [String], completion: @escaping ([String: PackState]) -> Void) {
      Task {
        var result: [String: PackState] = [:]
        for id in packs {
          let total = locked { sizes[id] } ?? 0
          if await isAvailable(id) {
            result[id] = packState(id, "completed", bytesDownloaded: total, totalBytes: total)
            continue
          }
          if let previous = locked({ last[id] }),
            let status = previous["status"] as? String, status != "completed"
          {
            result[id] = previous
            continue
          }
          // Not on the device: look up its size (this may ask the server).
          do {
            let pack = try await manager.assetPack(withID: id)
            remember(pack)
            result[id] = packState(id, "notInstalled", totalBytes: Int64(pack.downloadSize))
          } catch {
            result[id] = packState(id, "failed", error: error)
          }
        }
        completion(result)
      }
    }

    func fetch(_ packs: [String], completion: @escaping (Error?) -> Void) {
      Task {
        var started: [(String, AssetPack)] = []
        for id in packs {
          if await isAvailable(id) { continue }
          do {
            let pack = try await manager.assetPack(withID: id)
            remember(pack)
            started.append((id, pack))
          } catch {
            report(packState(id, "failed", error: error))
          }
        }
        // The request is made once each pack is looked up; the downloads
        // themselves report through statusUpdates.
        completion(nil)
        for (id, pack) in started {
          report(packState(id, "pending", totalBytes: Int64(pack.downloadSize)))
          Task {
            do {
              if #available(iOS 26.4, *) {
                try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
              } else {
                try await manager.ensureLocalAvailability(of: pack)
              }
              let total = Int64(pack.downloadSize)
              report(packState(id, "completed", bytesDownloaded: total, totalBytes: total))
            } catch {
              report(packState(id, "failed", totalBytes: Int64(pack.downloadSize), error: error))
            }
          }
        }
      }
    }

    func path(_ pack: String, completion: @escaping (String?) -> Void) {
      Task {
        guard await isAvailable(pack) else { return completion(nil) }
        completion(directoryPath(try? manager.url(for: FilePath(pack))))
      }
    }

    func release(_ pack: String) {}
  }
#endif
