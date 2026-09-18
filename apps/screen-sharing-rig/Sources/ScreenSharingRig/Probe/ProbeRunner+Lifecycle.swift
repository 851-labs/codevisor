import ScreenSharingDiagnostics
#if os(macOS)
  import AppKit
  import ScreenSharing
  import ScreenSharingWebRTC
  import Foundation
  import QuartzCore
  import ScreenCaptureKit
  @preconcurrency import WebRTC

  extension ProbeRunner {
    func deliveryValues() -> [String: Int] {
      let sent = senderMetrics.snapshot().counters
      let received = receiverMetrics.snapshot().counters
      return [
        // Every callback bucket once; captureSamplesWithoutImage is a sub-count of complete and is NOT added.
        "anyCallbackIncludingInvalidOrMissingStatus": ScreenSharingCaptureCallbackAccounting.callbackTotal(
          counters: sent),
        "completeStatusCallbacks": sent["captureCallbacksComplete", default: 0],
        "acceptedCapturedFrames": sent["capturedFrames", default: 0],
        "decodedFrames": received["decodedFrames", default: 0],
      ]
    }

    /// One tick of first-observed delivery; writes the first-callback /
    /// first-frame sidecars the first time their metric becomes non-zero.
    func recordFirstObservation(elapsedSeconds: Double) throws {
      guard firstObservation != nil else { return }
      let values = deliveryValues()
      let newly = firstObservation!.record(elapsedSeconds: elapsedSeconds, values: values)
      guard let report = options.reportURL else { return }
      for name in newly {
        let sidecar: String? =
          name == "anyCallbackIncludingInvalidOrMissingStatus"
          ? "first-callback" : name == "acceptedCapturedFrames" ? "first-frame" : nil
        guard let sidecar else { continue }
        let record: [String: Any] = [
          "metric": name, "observedAtSeconds": elapsedSeconds, "tick": (firstObservation?.ticks ?? 1) - 1,
          "values": values,
          "resolution": ScreenSharingFirstObservation.resolution,
          "definition": sidecar == "first-frame"
            ? "first measurement tick with capturedFrames > 0 (frames ACCEPTED by the sender), not merely a complete-status callback"
            : "first measurement tick with any SCK callback counter > 0, including invalid/missing-status samples",
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: report.path + ".\(sidecar).json"), options: .atomic)
      }
    }

    func publishFirstObservationLabels() {
      guard let firstObservation else { return }
      for (name, metric) in firstObservation.summary {
        senderMetrics.label(
          "firstObserved." + name, metric["firstObservedAtSeconds"] ?? ScreenSharingFirstObservation.neverObserved)
      }
      senderMetrics.label("firstObservedResolution", ScreenSharingFirstObservation.resolution)
    }

    /// The final event-log record: the diagnostic's own when it was constructed, otherwise (options requested a
    /// log but the probe failed earlier) an explicit not-initialized record; nil when no log was requested.
    func rtcEventLogRecord(
      role: ScreenSharingRtcEventLogDiagnostic.Role, reason: String
    ) -> ScreenSharingRtcEventLogDiagnostic.Record? {
      let log = role == .receiver ? rtcEventLog : senderRtcEventLog
      if let log { return log.record }
      let window = role == .receiver ? options.rtcEventLogWindow : options.senderRtcEventLogWindow
      let path = role == .receiver ? options.rtcEventLogPath : options.senderRtcEventLogPath
      guard let window, let path else { return nil }
      return .notInitialized(
        beginSeconds: window.beginSeconds, durationSeconds: window.durationSeconds, path: path,
        maxSizeBytes: ScreenSharingRtcEventLogDiagnostic.fixedMaxSizeBytes, reason: reason, role: role)
    }

    /// Shared finalization (normal completion, failure, window close): after the actual stop, publish the record
    /// atomically as REPORT.rtc-event-log.json so the brackets and close reason survive even without a report.
    /// A write error is recorded and printed, never a silent success. Idempotent per process.
    func publishRtcEventLogSidecar(role: ScreenSharingRtcEventLogDiagnostic.Role) {
      guard rtcEventLogSidecarOutcomes[role] == nil, let url = options.reportURL,
        let record = rtcEventLogRecord(role: role, reason: "probe stopped before the peer and the log were constructed")
      else { return }
      let suffix = role == .receiver ? ".rtc-event-log.json" : ".sender-rtc-event-log.json"
      let sidecar = URL(fileURLWithPath: url.path + suffix)
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: sidecar, options: .atomic)
        rtcEventLogSidecarOutcomes[role] = "written \(sidecar.path)"
      } catch {
        rtcEventLogSidecarOutcomes[role] = "write failed: \(error.localizedDescription)"
        FileHandle.standardError.write(
          Data("RTC event log sidecar (\(role.rawValue)): \(rtcEventLogSidecarOutcomes[role] ?? "")\n".utf8))
      }
    }

    /// The role's final event-log record as a JSON object for the failure record; nil when no log was requested.
    func failureRecordJSON(role: ScreenSharingRtcEventLogDiagnostic.Role) -> Any? {
      let reason = "probe failed before the peer and the log were constructed"
      guard let record = rtcEventLogRecord(role: role, reason: reason) else { return nil }
      return (try? JSONEncoder().encode(record)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// Durable failure evidence: written after cleanup on any failed run so the
    /// original error, a stop failure, the owned window's real lifecycle, every
    /// snapshot already taken (readiness / before-start / after-start / pause /
    /// stop) and the first-observed delivery state survive even when the normal
    /// report was never written. A final observation is taken only if
    /// measurement had begun; elapsed times are never invented.
    func writeFailureRecord(_ error: any Error) {
      guard let url = options.reportURL else { return }
      if firstObservation != nil, let startedNs = measurementStartedNs {
        try? recordFirstObservation(elapsedSeconds: Double(ScreenSharingMetrics.nowNs - startedNs) / 1_000_000_000)
        publishFirstObservationLabels()
      }
      let sent = senderMetrics.snapshot()
      let record: [String: Any] = [
        "failure": error.localizedDescription, "failedAtUptimeNs": ScreenSharingMetrics.nowNs,
        "reportWritten": FileManager.default.fileExists(atPath: url.path),
        "captureStopFailed": sent.labels["captureStopFailed"] ?? "none",
        "captureStopCompletedAtNs": sent.labels["captureStopCompletedAtNs"] ?? "none",
        "captureError": sent.labels["captureError"] ?? "none",
        "ownedWorkload": ownedWorkload?.lifecycleRecord ?? "not used",
        "ownedWorkloadCleanup": sent.labels["ownedWorkloadCleanup"] ?? "none",
        "firstObservations": firstObservation?.summary ?? "measurement never began",
        "firstObservationTicks": firstObservation?.ticks ?? 0,
        "snapshots": ownedWorkload?.snapshots ?? "not used",
        "observationAtFailure": ownedWorkload?.observation("failure record (after cleanup)") ?? "not used",
        // The event-log diagnostic record survives a failure (stop() already closed it before peer teardown and
        // published the sidecar); a request that never reached construction is stated as not initialized.
        "rtcEventLog": failureRecordJSON(role: .receiver) ?? "not requested",
        "rtcEventLogSidecar": rtcEventLogSidecarOutcomes[.receiver] ?? "not requested",
        "senderRtcEventLog": failureRecordJSON(role: .sender) ?? "not requested",
        "senderRtcEventLogSidecar": rtcEventLogSidecarOutcomes[.sender] ?? "not requested",
      ]
      try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: url.path + ".failure.json"), options: .atomic)
      // Draw timestamps already recorded survive a failure too (same schema, marked partial).
      if let workload = ownedWorkload,
        var times = workload.workloadTimesReport(
          mediaMeasuredSeconds: measurementStartedNs.map { Double(ScreenSharingMetrics.nowNs - $0) / 1_000_000_000 }
            ?? 0)
      {
        times["partial"] = true
        try? JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: url.path + ".workload-times.json"), options: .atomic)
      }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      Task { @MainActor in
        await stop(); exit(EXIT_SUCCESS)
      }
      return false
    }

    func stop() async {
      synthetic?.stop()
      synthetic = nil
      if ownedWorkload == nil { try? await capture?.stop() }
      if let workload = ownedWorkload {
        // Every exit path (normal, error, cancel) goes through one boundary:
        // the stop is credited only when the session recorded a successful
        // stream stop; the window closes in order or is abandoned; only this
        // window is ever hidden, at most once. A stop never attempted (error
        // before the normal end) is attempted here and its result preserved.
        if workload.lifecycle.state == .capturing || workload.lifecycle.state == .workloadPaused {
          await workload.stopCapture()
        }
        let outcome = workload.cleanUp()
        senderMetrics.label("ownedWorkloadCleanup", String(describing: outcome))
        senderMetrics.label("ownedWorkloadFinalState", workload.lifecycle.state.rawValue)
        if let closed = workload.lifecycle.timestampsNs[.close] {
          senderMetrics.label("ownedWorkloadClosedAtNs", String(closed))
        }
        if let abandoned = workload.lifecycle.timestampsNs[.abandon] {
          senderMetrics.label("ownedWorkloadAbandonedAtNs", String(abandoned))
          senderMetrics.label("ownedWorkloadAbandonedFrom", workload.lifecycle.abandonedFrom?.rawValue ?? "unknown")
        }
      }
      capture = nil
      picker?.stop()
      picker = nil
      // The standalone display link is invalidated before the renderer's
      // terminal stop so no supplied-drawable draw can follow it.
      displayLink?.stop()
      displayLink = nil
      metalView?.stop()
      // Failure, cancellation or early close: stop a started event log exactly once before the peer closes;
      // after a normal completion this is already final and does nothing.
      let measuredAtStop = mediaStartedNs.map { Double(ScreenSharingMetrics.nowNs - $0) / 1_000_000_000 }
      rtcEventLog?.closeEarly(measuredSeconds: measuredAtStop, reason: "runner stop before peer teardown")
      senderRtcEventLog?.closeEarly(measuredSeconds: measuredAtStop, reason: "runner stop before peer teardown")
      publishRtcEventLogSidecar(role: .receiver)
      publishRtcEventLogSidecar(role: .sender)
      sender?.close()
      receiver?.close()
      encoderLogger?.stop()
      encoderLogger = nil
      window?.orderOut(nil)
    }

    func checkQuality() async throws {
      guard let sender else { return }
      let original = options.configuration
      for (scale, fps) in [(1.0, 30), (0.75, 30), (0.5, 20), (1.0, 60)] {
        let video = try ScreenSharingVideoConfiguration(
          width: max(64, Int(Double(original.width) * scale) / 2 * 2),
          height: max(64, Int(Double(original.height) * scale) / 2 * 2),
          framesPerSecond: min(fps, original.framesPerSecond), bitrate: original.bitrate)
        synthetic?.stop()
        sender.updateVideoConfiguration(video)
        if let capture {
          try await capture.update(configuration: video)
        } else {
          synthetic = try SyntheticSource(
            configuration: video, sender: sender.frameSender, metrics: senderMetrics,
            pixelFormat: options.syntheticPixelFormat, desktopPattern: options.desktopPattern)
          synthetic?.start()
        }
        let frames = receiverMetrics.snapshot().counters["presentedFrames", default: 0]
        try await waitUntil(seconds: 15) { [self] in
          let snapshot = receiverMetrics.snapshot()
          return snapshot.labels["videoSize"] == "\(video.width) × \(video.height)"
            && snapshot.counters["presentedFrames", default: 0] >= frames + 6
        }
        print("Format transition: \(video.width) × \(video.height) at requested \(video.framesPerSecond) fps")
      }
      senderMetrics.label("qualityTransitions", "full30, 75%30, 50%20, full60 verified")
    }

    func readDescription(_ url: URL) throws -> ScreenSharingDescription {
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      let data = try file.read(upToCount: 256 * 1024 + 1) ?? Data()
      guard data.count <= 256 * 1024 else { throw ScreenSharingError.invalid("Signaling file is too large.") }
      return try JSONDecoder().decode(ScreenSharingDescription.self, from: data)
    }

    func writeDescription(_ description: ScreenSharingDescription, to url: URL) throws {
      // Publish a complete private file atomically, refusing to replace a prior
      // session. The receiver can never observe a partially written description.
      let data = try JSONEncoder().encode(description)
      let temporary = url.deletingLastPathComponent().appendingPathComponent(".screen-sharing-" + UUID().uuidString)
      let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { throw ScreenSharingError.unavailable("Cannot create private signaling file.") }
      defer { unlink(temporary.path) }
      let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try file.write(contentsOf: data)
      try file.close()
      guard link(temporary.path, url.path) == 0 else {
        throw ScreenSharingError.unavailable("Cannot publish signaling file; use fresh paths for each session.")
      }
    }

    /// Real diagnostic workflow, not a test synchronization primitive. Bounded
    /// polling allows a human to transfer the signaling file without a server.
    func waitUntil(seconds: Double, condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(seconds)
      while !condition() {
        guard ContinuousClock.now < deadline else { throw ScreenSharingError.unavailable("Probe setup timed out.") }
        try await Task.sleep(for: .milliseconds(100))
      }
    }
  }

#endif
