import Flutter
import UIKit

/// One pack's state, encoded the way the Dart side's `AssetPackState.fromMap`
/// reads it.
typealias PackState = [String: Any]

func packState(
  _ name: String, _ status: String, progress: Double = 0, bytesDownloaded: Int64 = 0,
  totalBytes: Int64 = 0, error: Error? = nil
) -> PackState {
  var state: PackState = [
    "name": name,
    "status": status,
    "progress": status == "completed" ? 1.0 : min(max(progress, 0), 1),
    "bytesDownloaded": bytesDownloaded,
    "totalBytes": totalBytes,
  ]
  if let error = error as NSError? {
    state["errorCode"] = error.code
    state["errorMessage"] = error.localizedDescription
  }
  return state
}

/// A delivery mechanism: On-Demand Resources or Background Assets. Callbacks
/// may arrive on any thread; the plugin hops to the main thread.
protocol PackBackend: AnyObject {
  var onUpdate: ((PackState) -> Void)? { get set }
  func states(_ packs: [String], completion: @escaping ([String: PackState]) -> Void)
  func fetch(_ packs: [String], completion: @escaping (Error?) -> Void)
  func path(_ pack: String, completion: @escaping (String?) -> Void)
  func release(_ pack: String)
}

public class StoreAssetPacksPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private lazy var backend: PackBackend = {
    let backend = StoreAssetPacksPlugin.makeBackend()
    backend.onUpdate = { [weak self] state in
      DispatchQueue.main.async { self?.sink?(state) }
    }
    return backend
  }()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StoreAssetPacksPlugin()
    let channel = FlutterMethodChannel(
      name: "store_asset_packs", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(
      name: "store_asset_packs/updates", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  /// Background Assets on iOS 26+ when the app's Info.plist opts in to
  /// Apple-hosted packs (`dart run store_asset_packs:ios` sets the keys);
  /// otherwise On-Demand Resources.
  static func makeBackend() -> PackBackend {
    if #available(iOS 26.0, *), usesAppleHostedAssetPacks() {
      return FallbackBackend(primary: BackgroundAssetsBackend(), fallback: OnDemandResourcesBackend())
    }
    return OnDemandResourcesBackend()
  }

  static func usesAppleHostedAssetPacks() -> Bool {
    let info = Bundle.main.infoDictionary ?? [:]
    return (info["BAHasManagedAssetPacks"] as? Bool ?? false)
      && (info["BAUsesAppleHosting"] as? Bool ?? false)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let packs = args["packs"] as? [String] ?? []
    let pack = args["pack"] as? String ?? ""
    func reply(_ value: Any?) { DispatchQueue.main.async { result(value) } }

    switch call.method {
    case "getStates":
      backend.states(packs) { reply($0) }
    case "fetch":
      backend.fetch(packs) { error in
        if let error = error as NSError? {
          reply(
            FlutterError(
              code: "store_asset_packs", message: error.localizedDescription,
              details: error.code))
        } else {
          reply(nil)
        }
      }
    case "getPackPath":
      backend.path(pack) { reply($0) }
    case "showCellularDataConfirmation":
      result(true)
    case "release":
      backend.release(pack)
      result(nil)
    case "getDevOverrideRoot":
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      result(documents.appendingPathComponent("store_asset_packs_dev").path)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    _ = backend  // start observing
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

/// The pack's folder in [bundle], if it is a directory. Packs are folder
/// references named after the pack (ODR) or archives whose root is a folder
/// named after the pack (Background Assets).
func directoryPath(_ url: URL?) -> String? {
  guard let url = url else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return url.path
}

/// Background Assets first, On-Demand Resources for any pack Background Assets
/// can't deliver: App Review disables Apple-hosted downloads, and unsigned or
/// development builds can't reach them. The app carries every pack as an ODR
/// tag too (`dart run store_asset_packs:ios odr`), under the same name.
final class FallbackBackend: PackBackend {
  var onUpdate: ((PackState) -> Void)?

  private let primary: PackBackend
  private let fallback: PackBackend
  private let lock = NSLock()
  /// Packs that Background Assets failed to deliver, now served by ODR.
  private var fellBack: Set<String> = []

  init(primary: PackBackend, fallback: PackBackend) {
    self.primary = primary
    self.fallback = fallback
    primary.onUpdate = { [weak self] state in self?.primaryUpdate(state) }
    fallback.onUpdate = { [weak self] state in self?.onUpdate?(state) }
  }

  private func hasFallenBack(_ pack: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return fellBack.contains(pack)
  }

  private func primaryUpdate(_ state: PackState) {
    let name = state["name"] as! String
    if hasFallenBack(name) { return }
    if state["status"] as? String == "failed" {
      lock.lock()
      fellBack.insert(name)
      lock.unlock()
      fallback.fetch([name]) { _ in }
      return
    }
    onUpdate?(state)
  }

  func states(_ packs: [String], completion: @escaping ([String: PackState]) -> Void) {
    primary.states(packs) { [weak self] primaryStates in
      guard let self = self else { return completion(primaryStates) }
      // Ask ODR about every pack Background Assets doesn't have.
      let others = packs.filter {
        self.hasFallenBack($0) || primaryStates[$0]?["status"] as? String != "completed"
      }
      if others.isEmpty { return completion(primaryStates) }
      self.fallback.states(others) { odrStates in
        var result = primaryStates
        for pack in others {
          guard let odr = odrStates[pack] else { continue }
          let odrStatus = odr["status"] as? String
          let primaryFailed = primaryStates[pack]?["status"] as? String == "failed"
          if self.hasFallenBack(pack) || primaryFailed || odrStatus == "completed" {
            result[pack] = odr
          }
        }
        completion(result)
      }
    }
  }

  func fetch(_ packs: [String], completion: @escaping (Error?) -> Void) {
    let odr = packs.filter(hasFallenBack)
    let ba = packs.filter { !hasFallenBack($0) }
    if !odr.isEmpty { fallback.fetch(odr) { _ in } }
    if ba.isEmpty { return completion(nil) }
    primary.fetch(ba, completion: completion)
  }

  func path(_ pack: String, completion: @escaping (String?) -> Void) {
    primary.path(pack) { [weak self] path in
      if let path = path { return completion(path) }
      guard let self = self else { return completion(nil) }
      self.fallback.path(pack, completion: completion)
    }
  }

  func release(_ pack: String) {
    fallback.release(pack)
  }
}
