import CodevisorCore
import Foundation
import Observation

extension LocalCodevisorServer {
  func startUpdateRequestMonitor() {
    guard managedService != nil, updateRequestMonitor == nil, updateRequestSource == nil else { return }
    let requestURL = Self.defaultAppUpdateRequestURL()
    consumePendingUpdateRequest(at: requestURL)
    let directory = requestURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else {
      updateRequestMonitor = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          self?.consumePendingUpdateRequest(at: requestURL)
          try? await Task.sleep(for: .seconds(5))
        }
      }
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: .write,
      queue: .main
    )
    source.setEventHandler { [weak self] in
      let consume: @MainActor () -> Void = {
        self?.consumePendingUpdateRequest(at: requestURL)
      }
      if Thread.isMainThread {
        MainActor.assumeIsolated(consume)
      } else {
        DispatchQueue.main.async(execute: consume)
      }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    updateRequestSource = source
  }

  private func consumePendingUpdateRequest(at requestURL: URL) {
    guard FileManager.default.fileExists(atPath: requestURL.path) else { return }
    try? FileManager.default.removeItem(at: requestURL)
    onUpdateRequested?()
  }

  func observeTermination(of process: Process) {
    process.terminationHandler = { [weak self] finished in
      let status = finished.terminationStatus
      Task { @MainActor in
        self?.handleTermination(process: finished, status: status)
      }
    }
  }

  private func handleTermination(process finished: Process, status: Int32) {
    if process === finished {
      process = nil
      activeBootId = nil
    }
    guard status == Self.updateHandoffExitStatus else { return }
    onUpdateRequested?()
  }
}
