import CodevisorCore
import Foundation
import Observation

extension LocalCodevisorServer {
    func startUpdateRequestMonitor() {
        guard managedService != nil, updateRequestMonitor == nil, updateRequestSource == nil else { return }
        let requestURL = Self.defaultAppUpdateRequestURL()
        // Consume a request written while nothing was watching, then watch
        // the directory for writes. The previous 1 Hz `stat` loop kept the
        // process waking every second for its entire lifetime — the kind of
        // permanent timer that blocks App Nap and shows up in powermetrics
        // as a never-quiet baseline.
        consumePendingUpdateRequest(at: requestURL)
        let directory = requestURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Fall back to the old poll (should not happen once the directory
            // above exists) at a gentler cadence.
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
            // Delivered on the .main queue, so the fast path always runs;
            // the dispatch fallback only guards against a stray off-main
            // delivery trapping `MainActor.assumeIsolated`.
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

    /// Watches the launched server for the update-handoff exit status, hopping
    /// to the main actor to invoke `onUpdateRequested`. Any other exit (a
    /// normal shutdown SIGTERM, a crash) is ignored — only the agreed status
    /// means "the app should update itself."
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
