import Foundation
import Testing

import ScreenSharing
@testable import ScreenSharingDiagnostics

/// Lifecycle of the receiver-only RTC event-log diagnostic with injected
/// clock/start/stop boundaries: window validation, once-only start and stop,
/// start false, stop boundary not invoked, cancellation and repeated cleanup,
/// late and missed ticks, zero-begin at the media-start tick, the sleep seam,
/// exclusive output reservation, preflight refusals, immutable record. The
/// fake start/stop advance the injected clock synchronously: these are
/// simulated-call-duration tests, not a concurrent held-call guarantee.
struct ScreenSharingRtcEventLogDiagnosticTests {
  private final class Fake {
    var now: Int64 = 1_000
    var startCalls: [(String, Int64)] = []
    var stopCalls = 0
    var startResult = true
    var stopResult = true
    var duringStart: Int64?
    var duringStop: Int64?
    var writeOnStart: Data?
    var boundaries: ScreenSharingRtcEventLogDiagnostic.Boundaries {
      .init(
        clock: { [self] in
          now += 1  // every read advances, so before < after is a real ordering, not equality
          return now
        },
        start: { [self] path, cap in
          startCalls.append((path, cap))
          now += 100  // simulated call duration; the bracket must enclose it
          duringStart = now
          if let data = writeOnStart { try? data.write(to: URL(fileURLWithPath: path)) }  // "wb" onto the reserved file
          return startResult
        },
        stop: { [self] in
          stopCalls += 1
          now += 100
          duringStop = now
          return stopResult
        })
    }
  }

  private struct Fixture {
    let log: ScreenSharingRtcEventLogDiagnostic
    let fake: Fake
    let directory: URL
    var path: String { log.path }
    func remove() { try? FileManager.default.removeItem(at: directory) }
  }

  private func make(begin: Double = 45, duration: Double = 70) throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-event-log-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("x.json.rtc-event-log.binarypb").path
    try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(path)  // option-time preflight passes on a fresh stem
    let fake = Fake()
    let log = ScreenSharingRtcEventLogDiagnostic(
      window: try .init(beginSeconds: begin, durationSeconds: duration), path: path, boundaries: fake.boundaries)
    return Fixture(log: log, fake: fake, directory: directory)
  }

  @Test func windowShapeIsBounded() throws {
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingRtcEventLogDiagnostic.Window(beginSeconds: -1, durationSeconds: 10)
    }
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingRtcEventLogDiagnostic.Window(beginSeconds: 0, durationSeconds: 0.5)
    }
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingRtcEventLogDiagnostic.Window(beginSeconds: 0, durationSeconds: 121)
    }
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingRtcEventLogDiagnostic.Window(beginSeconds: .nan, durationSeconds: 10)
    }
    let window = try ScreenSharingRtcEventLogDiagnostic.Window(beginSeconds: 45, durationSeconds: 70)
    #expect(window.endSeconds == 115 && ScreenSharingRtcEventLogDiagnostic.fixedMaxSizeBytes == 8 * 1024 * 1024)
  }

  @Test func normalLifecycleStartsAndStopsExactlyOnce() throws {
    let f = try make()
    defer { f.remove() }
    let (log, fake) = (f.log, f.fake)
    fake.writeOnStart = Data([0x82, 0x01])
    #expect(log.nextBoundarySeconds() == 45 && log.record.state == .waiting && !log.record.final)
    log.tick(measuredSeconds: 0)
    log.tick(measuredSeconds: 44.999)
    // nothing reserved before begin
    #expect(fake.startCalls.isEmpty && !FileManager.default.fileExists(atPath: f.path))
    log.tick(measuredSeconds: 45.003)
    #expect(fake.startCalls.count == 1 && fake.startCalls[0].0 == f.path && fake.startCalls[0].1 == 8 * 1024 * 1024)
    var r = log.record
    #expect(
      r.state == .started && r.startReturned == true && r.startApiInvoked && r.startAttemptedAtMeasuredSeconds == 45.003
    )
    #expect(r.outputReservation?.hasPrefix("reserved") == true)
    // the API overwrote only the reserved file
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data([0x82, 0x01]))
    let startBefore = try #require(r.startCallBeforeNs)
    let duringStart = try #require(fake.duringStart)
    let startAfter = try #require(r.startCallAfterNs)
    #expect(startBefore < duringStart && duringStart < startAfter)
    #expect(log.nextBoundarySeconds() == 115)
    log.tick(measuredSeconds: 46)
    log.tick(measuredSeconds: 114.9)
    #expect(fake.startCalls.count == 1 && fake.stopCalls == 0)
    log.tick(measuredSeconds: 115.001)
    r = log.record
    #expect(
      fake.stopCalls == 1 && r.state == .stopped && r.final && r.stopAttempted && r.stopApiInvoked
        && r.stoppedSuccessfulStart)
    #expect(r.stopAttemptedAtMeasuredSeconds == 115.001 && r.closeReason == "requested window end")
    let stopBefore = try #require(r.stopCallBeforeNs)
    let duringStop = try #require(fake.duringStop)
    let stopAfter = try #require(r.stopCallAfterNs)
    #expect(stopBefore < duringStop && duringStop < stopAfter)
    #expect(log.nextBoundarySeconds() == nil)
    // Immutable once final: later ticks, finish and early close change nothing and make no call.
    log.tick(measuredSeconds: 200)
    log.finish(measuredSeconds: 200)
    log.closeEarly(measuredSeconds: nil, reason: "x")
    #expect(log.record == r && fake.startCalls.count == 1 && fake.stopCalls == 1)
    #expect(
      r.requestedBeginSeconds == 45 && r.requestedEndSeconds == 115 && r.kind == "codevisor.rtcEventLogDiagnostic")
    #expect(r.notes.contains { $0.contains("[t, t+1) ms") } && r.notes.contains { $0.contains("not NIC arrival") })
    #expect(r.notes.contains { $0.contains("a write failure") })
  }

  @Test func startFalseIsNeverStopped() throws {
    let f = try make()
    defer { f.remove() }
    f.fake.startResult = false
    f.log.tick(measuredSeconds: 45)
    let r = f.log.record
    #expect(
      r.state == .startFailed && r.startReturned == false && r.startApiInvoked && r.final && !r.stopAttempted
        && !r.stoppedSuccessfulStart)
    #expect(r.closeReason == "start returned false at 45.0 s; no stop call" && f.log.nextBoundarySeconds() == nil)
    f.log.tick(measuredSeconds: 115)
    f.log.finish(measuredSeconds: 116)
    f.log.closeEarly(measuredSeconds: 117, reason: "failure")
    #expect(f.fake.startCalls.count == 1 && f.fake.stopCalls == 0 && f.log.record == r)
    // The owned empty reservation stays; it holds no evidence.
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path)).isEmpty)
  }

  @Test func stopNotInvokedByBoundaryIsNeverCredited() throws {
    let f = try make()
    defer { f.remove() }
    f.fake.stopResult = false  // the peer was already closed: the native stop API did not run
    f.log.tick(measuredSeconds: 45)
    f.log.tick(measuredSeconds: 115)
    let r = f.log.record
    #expect(
      f.fake.stopCalls == 1 && r.state == .stopSkipped && r.final && r.stopAttempted && !r.stopApiInvoked
        && !r.stoppedSuccessfulStart)
    #expect(r.closeReason?.contains("native API was not invoked") == true && r.stopCallBeforeNs != nil)
    f.log.closeEarly(measuredSeconds: 116, reason: "again")
    f.log.finish(measuredSeconds: 117)
    #expect(f.fake.stopCalls == 1 && f.log.record == r)  // once only, even when not credited
  }

  @Test func earlyCloseStopsOnceAndRepeatedCleanupIsNoOp() throws {
    let f = try make()
    defer { f.remove() }
    f.log.tick(measuredSeconds: 45)
    f.log.closeEarly(measuredSeconds: 60.5, reason: "runner stop")
    let r = f.log.record
    #expect(
      f.fake.stopCalls == 1 && r.state == .stopped && r.stoppedSuccessfulStart
        && r.stopAttemptedAtMeasuredSeconds == 60.5)
    #expect(r.closeReason == "early close: runner stop")
    f.log.closeEarly(measuredSeconds: 61, reason: "again")
    f.log.finish(measuredSeconds: 62)
    f.log.tick(measuredSeconds: 200)
    #expect(f.fake.stopCalls == 1 && f.log.record == r)
  }

  @Test func closeBeforeStartMakesNoCallAndNoReservation() throws {
    let f = try make()
    defer { f.remove() }
    f.log.tick(measuredSeconds: 10)
    f.log.closeEarly(measuredSeconds: 12, reason: "cancelled")
    let r = f.log.record
    #expect(
      r.state == .closedWithoutStart && r.final && r.startReturned == nil && !r.startApiInvoked && !r.stopAttempted)
    #expect(f.fake.startCalls.isEmpty && f.fake.stopCalls == 0 && !FileManager.default.fileExists(atPath: f.path))
    #expect(r.closeReason == "early close: cancelled; no start call was made")
    f.log.tick(measuredSeconds: 45)  // the window begin arriving later never starts a closed diagnostic
    #expect(f.fake.startCalls.isEmpty && f.log.record == r)
    let g = try make()
    defer { g.remove() }
    g.log.finish(measuredSeconds: 5)
    #expect(
      g.log.record.state == .closedWithoutStart
        && g.log.record.closeReason == "normal completion; no start call was made" && g.fake.startCalls.isEmpty)
  }

  @Test func lateStartAndMissedStopStayTruthful() throws {
    let f = try make()
    defer { f.remove() }
    f.log.tick(measuredSeconds: 47.5)  // a late tick: requested 45, actual 47.5, both kept
    #expect(f.log.record.startAttemptedAtMeasuredSeconds == 47.5 && f.log.record.requestedBeginSeconds == 45)
    f.log.tick(measuredSeconds: 100)
    f.log.finish(measuredSeconds: 130)  // no tick ever reached the end; the normal finish stops it and says so
    let r = f.log.record
    #expect(
      f.fake.stopCalls == 1 && r.stopAttemptedAtMeasuredSeconds == 130 && r.closeReason == "normal completion"
        && r.requestedEndSeconds == 115)
    // A first opportunity already past the requested end never starts (and reserves nothing).
    let late = try make(begin: 1, duration: 1)
    defer { late.remove() }
    late.log.tick(measuredSeconds: 5)
    #expect(late.log.record.state == .closedWithoutStart && late.fake.startCalls.isEmpty && late.log.record.final)
    #expect(
      late.log.record.closeReason?.hasPrefix(
        "first start opportunity at 5.0 s was already past the requested end 2.0 s") == true)
    #expect(!FileManager.default.fileExists(atPath: late.path))
  }

  @Test func zeroBeginStartsAtTheMediaStartTick() throws {
    let f = try make(begin: 0, duration: 1)
    defer { f.remove() }
    // begin 0 is not in the future
    #expect(ScreenSharingRtcEventLogDiagnostic.sleepSeconds(measured: 0, remaining: 200, nextBoundary: 0) == 1)
    f.log.tick(measuredSeconds: 0)  // the runner's media-start tick, before its first sleep
    #expect(
      f.log.record.state == .started && f.log.record.startAttemptedAtMeasuredSeconds == 0
        && f.log.nextBoundarySeconds() == 1)
    #expect(ScreenSharingRtcEventLogDiagnostic.sleepSeconds(measured: 0, remaining: 200, nextBoundary: 1) == 1)
    #expect(
      abs(ScreenSharingRtcEventLogDiagnostic.sleepSeconds(measured: 0.4, remaining: 200, nextBoundary: 1) - 0.6) < 1e-9)
    f.log.tick(measuredSeconds: 1.002)
    #expect(f.log.record.state == .stopped && f.fake.startCalls.count == 1 && f.fake.stopCalls == 1)
  }

  @Test func sleepSeamNeverExceedsTickRemainingOrNextBoundary() {
    let sleep = ScreenSharingRtcEventLogDiagnostic.sleepSeconds
    #expect(sleep(10, 200, nil, 1) == 1)
    #expect(sleep(199.7, 0.3, nil, 1) == 0.3)
    #expect(abs(sleep(44.2, 200, 45, 1) - 0.8) < 1e-9)  // floating-point subtraction: compare with tolerance
    #expect(abs(sleep(114.5, 0.2, 115, 1) - 0.2) < 1e-9)
    #expect(sleep(50, 200, 45, 1) == 1)  // a boundary already passed does not shorten the tick
    #expect(sleep(0, 0, nil, 1) == 0.001)  // never a non-positive sleep
  }

  @Test func entryAppearingAfterPreflightRefusesTheStartWithoutInvokingTheApi() throws {
    let f = try make()
    defer { f.remove() }
    // appears between option preflight and start
    try Data("prior evidence".utf8).write(to: URL(fileURLWithPath: f.path))
    f.log.tick(measuredSeconds: 45)
    let r = f.log.record
    #expect(
      f.fake.startCalls.isEmpty && r.state == .startRefused && r.final && !r.startApiInvoked && r.startReturned == nil
        && !r.stopAttempted)
    #expect(
      r.outputReservation?.hasPrefix("refused:") == true
        && r.closeReason == "output reservation failed at 45.0 s; start API not invoked")
    #expect(try Data(contentsOf: URL(fileURLWithPath: f.path)) == Data("prior evidence".utf8))
    f.log.finish(measuredSeconds: 200)
    #expect(f.fake.stopCalls == 0 && f.log.record == r)
    // A dangling symlink appearing after preflight refuses too, and stays.
    let g = try make()
    defer { g.remove() }
    try FileManager.default.createSymbolicLink(
      atPath: g.path, withDestinationPath: g.directory.appendingPathComponent("missing").path)
    g.log.tick(measuredSeconds: 45)
    #expect(g.fake.startCalls.isEmpty && g.log.record.state == .startRefused)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: g.path))?.hasSuffix("missing") == true)
    // A directory at the path refuses too.
    let h = try make()
    defer { h.remove() }
    try FileManager.default.createDirectory(atPath: h.path, withIntermediateDirectories: false)
    h.log.tick(measuredSeconds: 45)
    #expect(h.fake.startCalls.isEmpty && h.log.record.state == .startRefused)
  }

  @Test func preflightRefusesExistingEntriesAndUnknownErrors() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rtc-event-log-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(dir.appendingPathComponent("fresh.binarypb").path)
    let existing = dir.appendingPathComponent("existing.binarypb")
    try Data([1, 2, 3]).write(to: existing)
    #expect(throws: ScreenSharingError.self) { try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(existing.path) }
    #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
    let dangling = dir.appendingPathComponent("dangling.binarypb")
    try FileManager.default.createSymbolicLink(
      at: dangling, withDestinationURL: dir.appendingPathComponent("missing-target"))
    #expect(throws: ScreenSharingError.self) { try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(dangling.path) }
    #expect(throws: ScreenSharingError.self) { try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(dir.path) }
    // An lstat error other than absence (ENOTDIR: a path component is a regular file) is refused, not treated as free.
    #expect(throws: ScreenSharingError.self) {
      try ScreenSharingRtcEventLogDiagnostic.checkOutputPath(existing.appendingPathComponent("child").path)
    }
  }

  @Test func notInitializedRecordKeepsTheRequest() throws {
    let r = ScreenSharingRtcEventLogDiagnostic.Record.notInitialized(
      beginSeconds: 45, durationSeconds: 70, path: "/tmp/x.json.rtc-event-log.binarypb", maxSizeBytes: 8 * 1024 * 1024,
      reason: "probe failed before the receiver and the log were constructed")
    #expect(r.state == .notInitialized && r.final && !r.startApiInvoked && !r.stopAttempted && r.startReturned == nil)
    #expect(
      r.requestedEndSeconds == 115 && r.path.hasSuffix(".rtc-event-log.binarypb")
        && r.closeReason?.hasSuffix("; no API call") == true)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    #expect(object["state"] as? String == "notInitialized" && object["requestedBeginSeconds"] as? Double == 45)
  }

  @Test func roleIsCarriedInRecordNotesAndNotInitialized() throws {
    let f = try make()
    defer { f.remove() }
    #expect(f.log.role == .receiver && f.log.record.role == "receiver")
    #expect(f.log.record.notes.contains { $0.hasPrefix("receiver log:") })
    let sender = ScreenSharingRtcEventLogDiagnostic(
      window: try .init(beginSeconds: 45, durationSeconds: 70),
      path: f.directory.appendingPathComponent("s.json.sender-rtc-event-log.binarypb").path, role: .sender,
      boundaries: f.fake.boundaries)
    sender.tick(measuredSeconds: 45)
    sender.tick(measuredSeconds: 115)
    let r = sender.record
    #expect(r.role == "sender" && r.state == .stopped && r.stopApiInvoked)
    // the boundary is conditional: a successful SendRtp either sends directly or queues a network-thread task
    let senderNote = try #require(r.notes.first { $0.hasPrefix("sender log:") })
    #expect(senderNote.contains("TRANSPORT HAND-OFF") && senderNote.contains("never socket/NIC egress"))
    #expect(senderNote.contains("either sends directly") && senderNote.contains("queues a task there"))
    #expect(senderNote.contains("downstream unknowns"))
    #expect(!r.notes.contains { $0.hasPrefix("receiver log:") } && r.notes.contains { $0.hasPrefix("sender log:") })
    let n = ScreenSharingRtcEventLogDiagnostic.Record.notInitialized(
      beginSeconds: 1, durationSeconds: 2, path: "/x", maxSizeBytes: 8 * 1024 * 1024, reason: "failed early",
      role: .sender)
    #expect(n.role == "sender" && n.state == .notInitialized && n.notes.contains { $0.hasPrefix("sender log:") })
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    #expect(object["role"] as? String == "sender")
  }

  @Test func recordEncodesAsJSON() throws {
    let f = try make()
    defer { f.remove() }
    f.log.tick(measuredSeconds: 45)
    f.log.tick(measuredSeconds: 115)
    let data = try JSONEncoder().encode(f.log.record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      object["state"] as? String == "stopped" && object["stopApiInvoked"] as? Bool == true
        && object["maxSizeBytes"] as? Int == 8_388_608)
    #expect((object["notes"] as? [String])?.count == ScreenSharingRtcEventLogDiagnostic.notes(for: .receiver).count)
  }
}
