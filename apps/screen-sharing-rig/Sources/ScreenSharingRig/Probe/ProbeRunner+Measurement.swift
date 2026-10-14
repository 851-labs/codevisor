import ScreenSharingDiagnostics
#if os(macOS)
  import AppKit
  import ScreenSharing
  import Foundation
  import QuartzCore
  import ScreenCaptureKit
  @preconcurrency import WebRTC

  extension ProbeRunner {
    func measure() async throws {
      print(
        "Measuring \(options.duration) seconds of \(options.configuration.width)×\(options.configuration.height) video."
      )
      let started = ScreenSharingMetrics.nowNs
      mediaStartedNs = started
      let startedAtSeconds = CACurrentMediaTime()
      for metrics in [senderMetrics, receiverMetrics] { metrics.label("mediaStartUptimeNs", String(started)) }
      deliveryAudit?.start(originNs: Int64(startedAtSeconds * 1_000_000_000))
      rtcEventLog?.tick(measuredSeconds: 0)
      senderRtcEventLog?.tick(measuredSeconds: 0)
      receiverMetrics.label("idleAuditInstrumentation", "demand-attribution-1")
      if let report = options.reportURL {
        let ready: [String: Any] = [
          "startedAtSeconds": startedAtSeconds, "startedAtUptimeNs": started,
          "startedAtMediaTimeNs": Int64(CACurrentMediaTime() * 1_000_000_000),
          "meaning":
            "SETUP readiness: peers connected and the source (synthetic, display, picked or owned-window stream) started; not a first captured, encoded or decoded frame",
        ]
        try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
          .write(to: URL(fileURLWithPath: report.path + ".media-ready.json"), options: .atomic)
      }
      var transport = ProbeTransportTimeline()
      transport.append(
        elapsed: 0, sender: await sender?.statistics() ?? [:], receiver: await receiver?.statistics() ?? [:])
      var timeline = ProbeTimeline()
      timeline.append(
        elapsed: 0, sender: senderMetrics.snapshot(), receiver: receiverMetrics.snapshot(),
        drops: receiver?.mailbox.droppedFrames ?? 0)
      try timeline.writeProgress(to: options.reportURL)
      var measured = 0.0
      var sourcePausedAt: Double?
      var workloadPausedAt: Double?
      if options.captureOwnedWindow {
        firstObservation = ScreenSharingFirstObservation(names: [
          "anyCallbackIncludingInvalidOrMissingStatus", "completeStatusCallbacks", "acceptedCapturedFrames",
          "decodedFrames",
        ])
        measurementStartedNs = started
      }
      try recordFirstObservation(elapsedSeconds: measured)
      var idleCheckpointTaken = false
      var settlingCheckpointAtSeconds: Double?
      let settlingCounters = [
        (
          senderMetrics,
          ["capturedFrames", "encodedFrames", "refreshFrames", "videoRefreshRequestsReceived", "sourceIdleEvaluations"]
        ),
        (receiverMetrics, ["videoRefreshRequestsSent"]),
      ]
      while measured < options.duration {
        let boundaries = [rtcEventLog?.nextBoundarySeconds(), senderRtcEventLog?.nextBoundarySeconds()]
          .compactMap { $0 }
        try await Task.sleep(
          for: .seconds(
            ScreenSharingRtcEventLogDiagnostic.sleepSeconds(
              measured: measured, remaining: options.duration - measured, nextBoundary: boundaries.min())))
        measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
        rtcEventLog?.tick(measuredSeconds: measured)
        senderRtcEventLog?.tick(measuredSeconds: measured)
        if let pauseAfter = options.pauseSourceAfterSeconds, sourcePausedAt == nil, measured >= pauseAfter {
          if options.finalBurstSignal, let report = options.reportURL {
            let signal: [String: Any] = [
              "signalAtSeconds": CACurrentMediaTime(), "measuredSeconds": measured, "continueMilliseconds": 250,
            ]
            try JSONSerialization.data(withJSONObject: signal, options: [.sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".final-burst.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(250))
          }
          synthetic?.stop()
          senderMetrics.label("sourcePausedAtMediaTimeSeconds", String(CACurrentMediaTime()))
          measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
          sourcePausedAt = measured
          if let report = options.reportURL {
            let paused: [String: Any] = [
              "pausedAtSeconds": CACurrentMediaTime(), "pausedAtUptimeNs": ScreenSharingMetrics.nowNs,
              "measuredSeconds": measured,
              "latestCapturedTimestampNs": senderMetrics.snapshot().labels["latestCapturedTimestampNs"] ?? "none",
            ]
            try JSONSerialization.data(withJSONObject: paused, options: [.sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".source-paused.json"), options: .atomic)
          }
          senderMetrics.label("sourceIdleExperiment", "synthetic input stopped; observe automatic idle output")
          senderMetrics.label("sourcePausedAtSeconds", String(measured))
          senderMetrics.increment("sourcePauseEvents")
        }
        if let pauseAfter = options.pauseWorkloadAfterSeconds, workloadPausedAt == nil, measured >= pauseAfter,
          let workload = ownedWorkload
        {
          var record = try workload.pauseAnimation()
          measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
          workloadPausedAt = measured
          sourcePausedAt = measured
          let snapshot = senderMetrics.snapshot()
          record["measuredSeconds"] = measured
          record["capturedFramesAtPause"] = snapshot.counters["capturedFrames", default: 0]
          record["captureCallbacksCompleteAtPause"] = snapshot.counters["captureCallbacksComplete", default: 0]
          record["latestCapturedTimestampNs"] = snapshot.labels["latestCapturedTimestampNs"] ?? "none"
          if let report = options.reportURL {
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".workload-paused.json"), options: .atomic)
          }
          senderMetrics.label("sourceIdleExperiment", "owned workload animation paused; static window remains captured")
          senderMetrics.label("sourcePausedAtSeconds", String(measured))
          senderMetrics.label("workloadPausedAtSeconds", String(measured))
          senderMetrics.label("workloadPausedAtMediaTimeSeconds", String(CACurrentMediaTime()))
          senderMetrics.increment("workloadPauseEvents")
        }
        if options.idleOnDecoderReset, sourcePausedAt == nil,
          receiverMetrics.snapshot().counters["recoveryKeyframesReceived", default: 0] == 1
        {
          sourcePausedAt = measured
          senderMetrics.label("idleRecoveryObservedAtSeconds", String(measured))
        }
        if let sourcePausedAt, !idleCheckpointTaken, measured >= sourcePausedAt + 2 {
          let snapshot = senderMetrics.snapshot()
          senderMetrics.increment("capturedFramesAtIdleCheckpoint", by: snapshot.counters["capturedFrames", default: 0])
          senderMetrics.increment("encodedFramesAtIdleCheckpoint", by: snapshot.counters["encodedFrames", default: 0])
          senderMetrics.increment("refreshFramesAtIdleCheckpoint", by: snapshot.counters["refreshFrames", default: 0])
          senderMetrics.increment(
            "videoRefreshRequestsReceivedAtIdleCheckpoint",
            by: snapshot.counters["videoRefreshRequestsReceived", default: 0])
          receiverMetrics.increment(
            "videoRefreshRequestsSentAtIdleCheckpoint",
            by: receiverMetrics.snapshot().counters["videoRefreshRequestsSent", default: 0])
          senderMetrics.label("idleCheckpointAtSeconds", String(measured))
          idleCheckpointTaken = true
        }
        if options.headless, settlingCheckpointAtSeconds == nil, measured >= options.duration - 3 {
          for (metrics, names) in settlingCounters {
            let snapshot = metrics.snapshot()
            for name in names {
              metrics.increment(name + "AtSettlingCheckpoint", by: snapshot.counters[name, default: 0])
            }
            metrics.label("settlingCheckpointAtSeconds", String(measured))
          }
          settlingCheckpointAtSeconds = measured
        }
        try recordFirstObservation(elapsedSeconds: measured)
        transport.append(
          elapsed: measured, sender: await sender?.statistics() ?? [:], receiver: await receiver?.statistics() ?? [:])
        if measured - (timeline.samples.last?.elapsedSeconds ?? 0) >= Double(options.sampleIntervalSeconds)
          || measured >= options.duration
        {
          timeline.append(
            elapsed: measured, sender: senderMetrics.snapshot(), receiver: receiverMetrics.snapshot(),
            drops: receiver?.mailbox.droppedFrames ?? 0)
          try timeline.writeProgress(to: options.reportURL)
          print("Measurement progress: \(Int(measured)) / \(Int(options.duration)) seconds")
        }
      }
      rtcEventLog?.finish(measuredSeconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000)
      senderRtcEventLog?.finish(measuredSeconds: Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000)
      synthetic?.stop()
      if let workload = ownedWorkload {
        let stopped = await workload.stopCapture()
        guard stopped else {
          throw ScreenSharingError.unavailable(
            "Capture stop failed: \(senderMetrics.snapshot().labels["captureStopFailed"] ?? "unknown error").")
        }
      } else {
        try await capture?.stop()
      }
      if let workload = ownedWorkload {
        measured = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
        try recordFirstObservation(elapsedSeconds: measured)
        publishFirstObservationLabels()
        let snapshot = senderMetrics.snapshot()
        var stopped: [String: Any] = [
          "captureStopRequestedAtNs": snapshot.labels["captureStopRequestedAtNs"] ?? "none",
          "captureStopCompletedAtNs": snapshot.labels["captureStopCompletedAtNs"] ?? "none",
          "capturedFrames": snapshot.counters["capturedFrames", default: 0],
          "lifecycle": workload.lifecycleRecord,
          "observationAfterStop": workload.observation("after capture stop completed"),
          "firstObservations": firstObservation?.summary ?? "measurement never began",
        ]
        for name in ScreenSharingCaptureCallbackAccounting.Status.allCases.map(\.counterName)
          + [
            ScreenSharingCaptureCallbackAccounting.otherStatusCounter,
            ScreenSharingCaptureCallbackAccounting.invalidSampleCounter,
            ScreenSharingCaptureCallbackAccounting.missingStatusCounter,
            ScreenSharingCaptureCallbackAccounting.missingImageCounter,
          ]
        {
          stopped[name] = snapshot.counters[name, default: 0]
        }
        if let report = options.reportURL {
          try JSONSerialization.data(withJSONObject: stopped, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report.path + ".capture-stopped.json"), options: .atomic)
          if let times = workload.workloadTimesReport(mediaMeasuredSeconds: measured) {
            try JSONSerialization.data(withJSONObject: times, options: [.prettyPrinted, .sortedKeys])
              .write(to: URL(fileURLWithPath: report.path + ".workload-times.json"), options: .atomic)
          }
        }
      }
      let elapsed = Double(ScreenSharingMetrics.nowNs - started) / 1_000_000_000
      let senderStats = await sender?.statistics() ?? [:]
      let receiverStats = await receiver?.statistics() ?? [:]
      if options.headless, let latest = receiver?.mailbox.take() {
        receiverMetrics.label("latestReceivedRtpTimestamp", String(latest.rtpTimestamp))
      }
      let sent = senderMetrics.snapshot()
      let received = receiverMetrics.snapshot()
      func sinceCheckpoint(_ snapshot: ScreenSharingMetrics.Snapshot, _ name: String) -> Int {
        snapshot.counters[name, default: 0] - snapshot.counters[name + "AtIdleCheckpoint", default: 0]
      }
      func settled(_ snapshot: ScreenSharingMetrics.Snapshot, _ name: String) -> Bool {
        snapshot.counters[name, default: 0] == snapshot.counters[name + "AtSettlingCheckpoint", default: 0]
      }
      let settlingObserved = settlingCheckpointAtSeconds.map { elapsed - $0 >= 2 } ?? false
      let idleObservationPassed =
        (options.pauseSourceAfterSeconds == nil && !options.idleOnDecoderReset)
        || (idleCheckpointTaken && sinceCheckpoint(sent, "capturedFrames") == 0
          && sinceCheckpoint(sent, "encodedFrames") <= sinceCheckpoint(sent, "refreshFrames")
          && sinceCheckpoint(sent, "refreshFrames") <= sinceCheckpoint(sent, "videoRefreshRequestsReceived")
          && (received.counters["sourceIdleRefreshRequests", default: 0] > 0
            || sinceCheckpoint(received, "videoRefreshRequestsSent") == 0)
          && settlingObserved
          && settlingCounters.allSatisfy { metrics, names in
            let snapshot = metrics === senderMetrics ? sent : received
            return names.allSatisfy { settled(snapshot, $0) }
          })
      let idleResetPassed =
        !options.idleOnDecoderReset || sent.counters["captureDeliveryStoppedAtDecoderReset", default: 0] == 1
      let encoderRetryPassed =
        !options.dropRecoveryKeyframe
        || (sent.counters["injectedEncoderKeyframeDrops", default: 0] == 1
          && sent.counters["encoderRetriedKeyframes", default: 0] >= 1
          && sent.counters["encoderForcedKeyframesSubmitted", default: 0] >= 3)
      let recoveryPassed =
        !options.checkRecovery
        || (received.counters["injectedDecoderResets", default: 0] == 1
          && received.counters["recoveryKeyframesReceived", default: 0] == 1
          && received.counters["decodedFrames", default: 0] >= (options.idleOnDecoderReset ? 120 : 126)
          && (options.headless || received.counters["presentedFrames", default: 0] >= 126)
          && (received.timings["decoderResetToRecoveryKeyframe"]?.maximumMs ?? .infinity) < 2000)
      let ownedWindowPassed =
        !options.captureOwnedWindow
        || (sent.labels["captureStartedAtNs"] != nil && sent.labels["captureStopCompletedAtNs"] != nil
          && sent.counters["captureCallbacksComplete", default: 0] > 0
          && (options.pauseWorkloadAfterSeconds == nil || workloadPausedAt != nil))
      let passed =
        ownedWindowPassed
        && (sender == nil || sent.counters["encodedFrames", default: 0] > 0)
        && (receiver == nil
          || received.counters[options.headless ? "decodedFrames" : "presentedFrames", default: 0] > 0)
        && sent.labels["captureError"] == nil && sent.labels["encoderError"] == nil
        && received.labels["decoderError"] == nil
        && sent.counters["encodeErrors", default: 0] == 0 && received.counters["decodeErrors", default: 0] == 0
        && sent.counters["syntheticDrawErrors", default: 0] == 0
        && sent.counters["syntheticConversionErrors", default: 0] == 0
        && received.counters["renderErrors", default: 0] == 0
        && recoveryPassed
        && encoderRetryPassed
        && idleObservationPassed
        && idleResetPassed
      let report = ProbeReport(
        mode: options.mode, configuration: options.configuration,
        source: options.mode == .receive
          ? "remote"
          : options.captureOwnedWindow
            ? "ScreenCaptureKit owned window"
            : (options.displayID != nil || options.capturePicker) ? "ScreenCaptureKit" : "synthetic",
        startedAtSeconds: startedAtSeconds, elapsedSeconds: elapsed,
        passed: passed, renderingEnabled: receiver != nil && !options.headless, sender: sent,
        receiver: received,
        senderRTC: senderStats, receiverRTC: receiverStats,
        rendererMailboxDrops: receiver?.mailbox.droppedFrames ?? 0,
        presentedFramesPerSecond: Double(
          received.counters["presentedFrames", default: 0]
            - (timeline.samples.first?.receiver.counters["presentedFrames"] ?? 0)) / elapsed,
        timeline: timeline.samples, transportTimeline: transport.samples,
        receiverDeliveryAudit: deliveryAudit?.snapshot(), receiverRtcEventLog: rtcEventLog?.record,
        senderRtcEventLog: senderRtcEventLog?.record)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(report)
      if let url = options.reportURL { try data.write(to: url, options: .atomic) }
      print(String(decoding: data, as: UTF8.self))
      let cacheHeldBeforeClose = sender?.frameSender.isHoldingCachedFrame
      await stop()
      func observation() throws -> [String: Any] {
        let sent = senderMetrics.snapshot()
        let received = receiverMetrics.snapshot()
        return [
          "cacheHeld": sender?.frameSender.isHoldingCachedFrame ?? false,
          "mailboxHeld": receiver?.mailbox.isHolding ?? false,
          "encoderPendingAtStop": sent.labels["encoderPendingAtStop"] ?? "not observed",
          "sender": try JSONSerialization.jsonObject(with: encoder.encode(sent)),
          "receiver": try JSONSerialization.jsonObject(with: encoder.encode(received)),
        ]
      }
      let immediate = try observation()
      let senderTasks = await sender?.awaitClosed()
      let receiverTasks = await receiver?.awaitClosed()
      let drained = try observation()
      try await Task.sleep(for: .milliseconds(500))
      let settled = try observation()
      let tracked = [
        "capturedFrames", "encodedFrames", "refreshFrames", "sourceIdleEvaluations", "decodedFrames",
        "videoRefreshRequestsSent", "videoRefreshRequestsReceived",
      ]
      func counters(_ observation: [String: Any]) -> [String: Int] {
        var result: [String: Int] = [:]
        for side in ["sender", "receiver"] {
          let values = (observation[side] as? [String: Any])?["counters"] as? [String: Int] ?? [:]
          for name in tracked { result[side + "." + name] = values[name] ?? 0 }
        }
        return result
      }
      let movedCounters = counters(drained).filter { counters(settled)[$0.key] != $0.value }.keys.sorted()
      let closeCheckPassed =
        movedCounters.isEmpty && settled["cacheHeld"] as? Bool == false && settled["mailboxHeld"] as? Bool == false
        && (ownedWorkload?.session.completedInOrder ?? true)
      let closed: [String: Any] = [
        "applicable": true, "passed": closeCheckPassed,
        "cacheHeldBeforeClose": cacheHeldBeforeClose ?? false,
        "ownedTasksAwaited": ["sender": senderTasks ?? -1, "receiver": receiverTasks ?? -1],
        "immediate": immediate, "afterOwnedWorkDrained": drained, "afterObservationWindow": settled,
        "observationWindowMilliseconds": 500, "trackedCounters": tracked, "movedCounters": movedCounters,
        "rtcEventLogSidecar": rtcEventLogSidecarOutcomes[.receiver] ?? "not requested",
        "senderRtcEventLogSidecar": rtcEventLogSidecarOutcomes[.sender] ?? "not requested",
        "quiescentOverObservationWindow": closeCheckPassed,
        "scope": "owned main-actor tasks awaited; WebRTC and VideoToolbox threads not covered",
        "ownedWorkload": ownedWorkload?.lifecycleRecord ?? "not used",
      ]
      if let url = options.reportURL {
        try JSONSerialization.data(withJSONObject: closed, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: url.path + ".after-close.json"), options: .atomic)
      }
      guard passed else { throw ScreenSharingError.unavailable("Media did not pass the probe. See the metrics above.") }
      guard closeCheckPassed else {
        throw ScreenSharingError.unavailable(
          "Close check failed: cache/mailbox retained, counters moved (\(movedCounters.joined(separator: ", ")))"
            + " or the owned window did not close in order.")
      }
    }

  }
#endif
