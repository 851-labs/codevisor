import CoreMedia
import Foundation
import ScreenCaptureKit

struct ComputerUseShareKey: Hashable, Sendable {
    let sessionID: String
    let pid: pid_t
}

enum ComputerUseNativePreviewMetrics {
    static let maximumDimension: CGFloat = 960
    static let fallbackSize = CGSize(width: 640, height: 360)
    static let framesPerSecond: Int32 = 5
    static let queueDepth = 2
}

/// Produces an even-sized, aspect-preserving preview buffer. The model still
/// receives an independent full-resolution screenshot on demand; this stream
/// exists for macOS's native sharing UI and lifecycle.
func computerUseNativePreviewSize(
    windowFrame: CGRect,
    pointPixelScale: CGFloat,
    maximumDimension: CGFloat = ComputerUseNativePreviewMetrics.maximumDimension
) -> CGSize {
    guard windowFrame.width.isFinite,
          windowFrame.height.isFinite,
          windowFrame.width > 0,
          windowFrame.height > 0,
          pointPixelScale.isFinite,
          pointPixelScale > 0,
          maximumDimension.isFinite,
          maximumDimension >= 2
    else { return ComputerUseNativePreviewMetrics.fallbackSize }

    let nativeSize = CGSize(
        width: windowFrame.width * pointPixelScale,
        height: windowFrame.height * pointPixelScale
    )
    let reduction = min(1, maximumDimension / max(nativeSize.width, nativeSize.height))

    func evenDimension(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int((value * reduction).rounded(.down)) & ~1))
    }

    return CGSize(
        width: evenDimension(nativeSize.width),
        height: evenDimension(nativeSize.height)
    )
}

/// ScreenCaptureKit delivers picker observer callbacks on an internal queue,
/// while `SCStream` and `SCContentFilter` have not adopted `Sendable`. Keep the
/// unchecked crossing tightly scoped to the hop into this type's main-actor
/// state rather than asserting that the callbacks themselves run on main.
private struct ComputerUseUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Maintains one native ScreenCaptureKit stream per controlled window. Session
/// permissions reference that shared stream, while model screenshots remain
/// on-demand through SCScreenshotManager.
@MainActor
final class ComputerUseNativeSharing: NSObject,
    SCStreamDelegate,
    SCStreamOutput,
    SCContentSharingPickerObserver
{
    static let shared = ComputerUseNativeSharing()

    private struct Entry {
        let windowID: CGWindowID
        let stream: SCStream
        var keys: Set<ComputerUseShareKey>
        var pointPixelScale: CGFloat
        var outputSize: CGSize
    }

    private var entriesByWindowID: [CGWindowID: Entry] = [:]
    private var windowIDByKey: [ComputerUseShareKey: CGWindowID] = [:]
    private var pendingKeysByWindowID: [CGWindowID: Set<ComputerUseShareKey>] = [:]
    private var pendingWindowIDByKey: [ComputerUseShareKey: CGWindowID] = [:]
    private var windowIDByStream: [ObjectIdentifier: CGWindowID] = [:]
    private var intentionallyStopping: Set<ObjectIdentifier> = []
    private let outputQueue = DispatchQueue(
        label: "com.codevisor.computer-use.screen-share",
        qos: .utility
    )

    private override init() {
        super.init()
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        // A sharing stream must originate from an active Computer Use session;
        // Control Center may manage existing streams but cannot create an
        // unowned one that has no session or permission policy behind it.
        picker.maximumStreamCount = 0
    }

    deinit {
        SCContentSharingPicker.shared.remove(self)
    }

    func activate(
        sessionID: String,
        pid: pid_t,
        windowID: CGWindowID?,
        windowFrame: CGRect
    ) {
        guard let windowID, !sessionID.isEmpty else { return }
        let key = ComputerUseShareKey(sessionID: sessionID, pid: pid)
        guard !ComputerUseRevocations.shared.contains(key) else { return }

        if windowIDByKey[key] == windowID {
            refreshPreviewConfiguration(windowID: windowID, windowFrame: windowFrame)
            return
        }
        if pendingWindowIDByKey[key] == windowID { return }

        detach(key: key, intentional: true)

        if var entry = entriesByWindowID[windowID] {
            entry.keys.insert(key)
            entriesByWindowID[windowID] = entry
            windowIDByKey[key] = windowID
            refreshPreviewConfiguration(windowID: windowID, windowFrame: windowFrame)
            return
        }

        let beginsStart = pendingKeysByWindowID[windowID] == nil
        pendingKeysByWindowID[windowID, default: []].insert(key)
        pendingWindowIDByKey[key] = windowID
        guard beginsStart else { return }

        Task { @MainActor [weak self] in
            await self?.start(windowID: windowID)
        }
    }

    func end(sessionID: String) {
        let keys = Set(windowIDByKey.keys.filter { $0.sessionID == sessionID })
            .union(pendingWindowIDByKey.keys.filter { $0.sessionID == sessionID })
        keys.forEach { detach(key: $0, intentional: true) }
        ComputerUseRevocations.shared.clear(sessionID: sessionID)
        deactivatePickerIfIdle()
    }

    func stopUsing(pid: pid_t) {
        let keys = Set(windowIDByKey.keys.filter { $0.pid == pid })
            .union(pendingWindowIDByKey.keys.filter { $0.pid == pid })
        for key in keys {
            ComputerUseRevocations.shared.insert(key)
            detach(key: key, intentional: true)
        }
        deactivatePickerIfIdle()
    }

    func endAll() {
        let active = Array(entriesByWindowID.values)
        entriesByWindowID.removeAll()
        windowIDByKey.removeAll()
        pendingKeysByWindowID.removeAll()
        pendingWindowIDByKey.removeAll()
        windowIDByStream.removeAll()
        for entry in active { stop(entry, intentional: true) }
        ComputerUseRevocations.shared.clearAll()
        SCContentSharingPicker.shared.isActive = false
    }

    private func start(windowID: CGWindowID) async {
        defer { deactivatePickerIfIdle() }
        do {
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                clearPending(windowID: windowID)
                Log.computerUse.error(
                    "Unable to start native sharing: window \(windowID, privacy: .public) is no longer shareable"
                )
                return
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let pointPixelScale = max(1, CGFloat(filter.pointPixelScale))
            let outputSize = computerUseNativePreviewSize(
                windowFrame: window.frame,
                pointPixelScale: pointPixelScale
            )
            let stream = SCStream(
                filter: filter,
                configuration: previewConfiguration(size: outputSize),
                delegate: self
            )
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)

            var pickerConfiguration = SCContentSharingPickerConfiguration()
            pickerConfiguration.allowedPickerModes = .singleWindow
            pickerConfiguration.allowsChangingSelectedContent = false
            let picker = SCContentSharingPicker.shared
            picker.setConfiguration(pickerConfiguration, for: stream)
            picker.isActive = true

            try await stream.startCapture()

            let keys = takeValidPendingKeys(windowID: windowID)
            guard !keys.isEmpty else {
                picker.setConfiguration(nil, for: stream)
                try? await stream.stopCapture()
                return
            }

            let entry = Entry(
                windowID: windowID,
                stream: stream,
                keys: keys,
                pointPixelScale: pointPixelScale,
                outputSize: outputSize
            )
            entriesByWindowID[windowID] = entry
            keys.forEach { windowIDByKey[$0] = windowID }
            windowIDByStream[ObjectIdentifier(stream)] = windowID
        } catch {
            clearPending(windowID: windowID)
            Log.computerUse.error(
                "Unable to start native sharing for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func previewConfiguration(size: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: ComputerUseNativePreviewMetrics.framesPerSecond
        )
        configuration.queueDepth = ComputerUseNativePreviewMetrics.queueDepth
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        return configuration
    }

    private func refreshPreviewConfiguration(windowID: CGWindowID, windowFrame: CGRect) {
        guard var entry = entriesByWindowID[windowID] else { return }
        let desiredSize = computerUseNativePreviewSize(
            windowFrame: windowFrame,
            pointPixelScale: entry.pointPixelScale
        )
        guard desiredSize != entry.outputSize else { return }

        entry.outputSize = desiredSize
        entriesByWindowID[windowID] = entry
        let stream = entry.stream
        let configuration = previewConfiguration(size: desiredSize)
        Task { @MainActor [weak self] in
            do {
                try await stream.updateConfiguration(configuration)
                self?.reconcilePreviewConfiguration(
                    windowID: windowID,
                    stream: stream,
                    appliedSize: desiredSize
                )
            } catch {
                Log.computerUse.error(
                    "Unable to resize native sharing preview for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func reconcilePreviewConfiguration(
        windowID: CGWindowID,
        stream: SCStream,
        appliedSize: CGSize
    ) {
        guard let entry = entriesByWindowID[windowID],
              ObjectIdentifier(entry.stream) == ObjectIdentifier(stream),
              entry.outputSize != appliedSize
        else { return }

        let latestSize = entry.outputSize
        Task { @MainActor in
            do {
                try await stream.updateConfiguration(previewConfiguration(size: latestSize))
            } catch {
                Log.computerUse.error(
                    "Unable to reconcile native sharing preview for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func detach(key: ComputerUseShareKey, intentional: Bool) {
        if let pendingWindowID = pendingWindowIDByKey.removeValue(forKey: key) {
            pendingKeysByWindowID[pendingWindowID]?.remove(key)
            if pendingKeysByWindowID[pendingWindowID]?.isEmpty == true {
                pendingKeysByWindowID.removeValue(forKey: pendingWindowID)
            }
        }

        guard let windowID = windowIDByKey.removeValue(forKey: key),
              var entry = entriesByWindowID[windowID]
        else { return }
        entry.keys.remove(key)
        if entry.keys.isEmpty {
            entriesByWindowID.removeValue(forKey: windowID)
            stop(entry, intentional: intentional)
        } else {
            entriesByWindowID[windowID] = entry
        }
    }

    private func takeValidPendingKeys(windowID: CGWindowID) -> Set<ComputerUseShareKey> {
        let pending = pendingKeysByWindowID.removeValue(forKey: windowID) ?? []
        let valid = pending.filter { key in
            pendingWindowIDByKey[key] == windowID
                && !ComputerUseRevocations.shared.contains(key)
        }
        for key in pending where pendingWindowIDByKey[key] == windowID {
            pendingWindowIDByKey.removeValue(forKey: key)
        }
        return Set(valid)
    }

    private func clearPending(windowID: CGWindowID) {
        let pending = pendingKeysByWindowID.removeValue(forKey: windowID) ?? []
        for key in pending where pendingWindowIDByKey[key] == windowID {
            pendingWindowIDByKey.removeValue(forKey: key)
        }
    }

    private func stop(_ entry: Entry, intentional: Bool) {
        let identifier = ObjectIdentifier(entry.stream)
        windowIDByStream.removeValue(forKey: identifier)
        SCContentSharingPicker.shared.setConfiguration(nil, for: entry.stream)
        if intentional { intentionallyStopping.insert(identifier) }
        Task { @MainActor [weak self] in
            do {
                try await entry.stream.stopCapture()
            } catch {
                Log.computerUse.error(
                    "Unable to stop native sharing for window \(entry.windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            self?.intentionallyStopping.remove(identifier)
            self?.deactivatePickerIfIdle()
        }
    }

    private func deactivatePickerIfIdle() {
        if entriesByWindowID.isEmpty && pendingKeysByWindowID.isEmpty {
            SCContentSharingPicker.shared.isActive = false
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let identifier = ObjectIdentifier(stream)
        let nsError = error as NSError
        let userStopped = nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.userStopped.rawValue
        Task { @MainActor in
            guard !intentionallyStopping.contains(identifier),
                  let windowID = windowIDByStream.removeValue(forKey: identifier),
                  let entry = entriesByWindowID.removeValue(forKey: windowID)
            else { return }

            entry.keys.forEach { windowIDByKey.removeValue(forKey: $0) }
            if userStopped {
                for key in entry.keys {
                    ComputerUseRevocations.shared.insert(key)
                    ComputerUsePresentationState.shared.systemStopped(key: key)
                }
            } else {
                Log.computerUse.error(
                    "Native sharing stopped unexpectedly for window \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            deactivatePickerIfIdle()
        }
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // Receiving real, moderately sized frames keeps the system's live
        // sharing preview populated. Model screenshots remain on demand.
        guard type == .screen, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else {
            return
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {}

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        guard let stream else { return }
        let streamBox = ComputerUseUncheckedSendable(value: stream)
        let filterBox = ComputerUseUncheckedSendable(value: filter)
        Task { @MainActor [weak self, streamBox, filterBox] in
            guard let self else { return }
            let stream = streamBox.value
            let identifier = ObjectIdentifier(stream)
            guard self.windowIDByStream[identifier] != nil else { return }
            do {
                try await stream.updateContentFilter(filterBox.value)
            } catch {
                Log.computerUse.error(
                    "Unable to apply native sharing picker update: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Log.computerUse.error(
            "Native sharing picker failed: \(error.localizedDescription, privacy: .public)"
        )
    }
}

final class ComputerUseRevocations: @unchecked Sendable {
    static let shared = ComputerUseRevocations()

    private let lock = NSLock()
    private var keys: Set<ComputerUseShareKey> = []

    func contains(_ key: ComputerUseShareKey) -> Bool {
        lock.withLock { keys.contains(key) }
    }

    func insert(_ key: ComputerUseShareKey) {
        _ = lock.withLock { keys.insert(key) }
    }

    func clear(sessionID: String) {
        lock.withLock { keys = keys.filter { $0.sessionID != sessionID } }
    }

    func clearAll() {
        lock.withLock { keys.removeAll() }
    }
}
