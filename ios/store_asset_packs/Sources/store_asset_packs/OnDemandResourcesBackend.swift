import Foundation

/// On-Demand Resources: each pack is an ODR tag on a folder reference named
/// after the pack. A pack is available while its `NSBundleResourceRequest`
/// is accessing; the plugin keeps that request until `release`.
final class OnDemandResourcesBackend: NSObject, PackBackend {
  var onUpdate: ((PackState) -> Void)?

  private let lock = NSLock()
  /// Requests whose resources are being accessed (the pack is available).
  private var accessing: [String: NSBundleResourceRequest] = [:]
  /// Requests still downloading.
  private var loading: [String: NSBundleResourceRequest] = [:]
  private var observations: [String: NSKeyValueObservation] = [:]
  /// The last state reported per pack, so getStates can return a download's
  /// progress or a failure.
  private var last: [String: PackState] = [:]

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

  func states(_ packs: [String], completion: @escaping ([String: PackState]) -> Void) {
    let group = DispatchGroup()
    var result: [String: PackState] = [:]
    let resultLock = NSLock()
    func set(_ pack: String, _ state: PackState) {
      resultLock.lock()
      result[pack] = state
      resultLock.unlock()
    }
    for pack in packs {
      let (isAccessing, isLoading, previous) = locked {
        (accessing[pack] != nil, loading[pack] != nil, last[pack])
      }
      if isAccessing {
        set(pack, packState(pack, "completed"))
      } else if isLoading, let previous = previous {
        set(pack, previous)
      } else {
        group.enter()
        conditionallyAccess(pack) { available in
          if available {
            set(pack, packState(pack, "completed"))
          } else if let previous = previous,
            ["failed", "canceled"].contains(previous["status"] as? String)
          {
            set(pack, previous)
          } else {
            set(pack, packState(pack, "notInstalled"))
          }
          group.leave()
        }
      }
    }
    group.notify(queue: .main) { completion(result) }
  }

  /// Begins access if the pack is already on the device, without downloading.
  /// The request is kept on success.
  private func conditionallyAccess(_ pack: String, completion: @escaping (Bool) -> Void) {
    let request = NSBundleResourceRequest(tags: [pack])
    request.conditionallyBeginAccessingResources { [weak self] available in
      guard let self = self else { return completion(available) }
      if available {
        let kept = self.locked { () -> Bool in
          if self.accessing[pack] != nil { return false }
          self.accessing[pack] = request
          return true
        }
        // Another caller already holds access; balance this one.
        if !kept { request.endAccessingResources() }
      }
      completion(available)
    }
  }

  func fetch(_ packs: [String], completion: @escaping (Error?) -> Void) {
    for pack in packs {
      let busy = locked { accessing[pack] != nil || loading[pack] != nil }
      if busy { continue }
      let request = NSBundleResourceRequest(tags: [pack])
      locked { loading[pack] = request }
      report(packState(pack, "pending"))
      let observation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
        guard let self = self else { return }
        // ODR reports units, not bytes.
        let previous = self.locked { self.last[pack]?["progress"] as? Double ?? 0 }
        let fraction = progress.fractionCompleted
        if fraction < 1, fraction - previous < 0.01 { return }
        self.report(packState(pack, "downloading", progress: fraction))
      }
      locked { observations[pack] = observation }
      request.beginAccessingResources { [weak self] error in
        guard let self = self else { return }
        self.locked {
          self.loading[pack] = nil
          self.observations[pack]?.invalidate()
          self.observations[pack] = nil
        }
        if let error = error {
          let cancelled = request.progress.isCancelled
            || (error as NSError).code == NSUserCancelledError
          self.report(packState(pack, cancelled ? "canceled" : "failed", error: error))
        } else {
          let kept = self.locked { () -> Bool in
            if self.accessing[pack] != nil { return false }
            self.accessing[pack] = request
            return true
          }
          if !kept { request.endAccessingResources() }
          self.report(packState(pack, "completed"))
        }
      }
    }
    completion(nil)
  }

  func path(_ pack: String, completion: @escaping (String?) -> Void) {
    if let request = locked({ accessing[pack] }) {
      return completion(directoryPath(request.bundle.url(forResource: pack, withExtension: nil)))
    }
    conditionallyAccess(pack) { [weak self] available in
      guard available, let self = self, let request = self.locked({ self.accessing[pack] }) else {
        return completion(nil)
      }
      completion(directoryPath(request.bundle.url(forResource: pack, withExtension: nil)))
    }
  }

  func release(_ pack: String) {
    let request = locked { accessing.removeValue(forKey: pack) }
    request?.endAccessingResources()
    if request != nil { locked { last[pack] = nil } }
  }
}
