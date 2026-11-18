#if os(macOS)
  import CoreGraphics
  import CoreMedia
  import ScreenCaptureKit
  import Testing

  @testable import ScreenSharing

  @Suite @MainActor struct ScreenSharingCaptureChangesTests {
    @Test(arguments: [(1.0, true), (0.5, false)])
    func dirtyRectsReachTheSinkOnlyAtNativeScale(contentScale: Double, delivered: Bool) async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      let output = try #require(fixture.target.output)
      let rect = CGRect(x: 2, y: 4, width: 6, height: 8)
      output.deliver(try Self.sample(presentationNs: 1, contentScale: contentScale), of: .screen)
      let sample = try Self.sample(presentationNs: 2, contentScale: contentScale, dirtyRects: [rect])
      output.deliver(sample, of: .screen)
      #expect(fixture.sink.lastDirtyRects == (delivered ? [rect] : nil))
    }

    @Test(arguments: [
      (CaptureHistory.aFrame, true), (.aFrameThenAnIdleCallback, true), (.nothing, false),
      (.aFrameThenACallbackWithoutAPicture, false), (.aFrameThenAReconfigure, false), (.aFrameThenARestart, false),
    ])
    func dirtyRectsReachTheSinkOnlyWhenItGotTheFrameTheyAreMeasuredFrom(
      history: CaptureHistory, delivered: Bool
    ) async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      try await Self.replay(history, on: fixture)
      let rect = CGRect(x: 2, y: 4, width: 6, height: 8)
      let sample = try Self.sample(presentationNs: 9, contentScale: 1, dirtyRects: [rect])
      try #require(fixture.target.output).deliver(sample, of: .screen)
      #expect(fixture.sink.lastDirtyRects == (delivered ? [rect] : nil))
    }

    @Test func aFrameThatReportsNoChangedAreaLeavesItsChangesUnknown() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      let output = try #require(fixture.target.output)
      output.deliver(try Self.sample(presentationNs: 1, contentScale: 1), of: .screen)
      output.deliver(try Self.sample(presentationNs: 2, contentScale: 1, dirtyRects: [.zero]), of: .screen)
      #expect(fixture.sink.frames == [1, 2])
      #expect(fixture.sink.lastDirtyRects == nil)
    }

    @Test func framesThatArriveDuringAReconfigureAndTheFirstAfterItLeaveTheirChangesUnknown() async throws {
      let fixture = CaptureFixture()
      try await fixture.start()
      let output = try #require(fixture.target.output)
      let held = CaptureGate()
      fixture.stream.holdUpdate = held
      let rect = CGRect(x: 2, y: 4, width: 6, height: 8)
      var delivered: [[CGRect]?] = []
      let deliver = { (presentationNs: Int64) in
        output.deliver(
          try Self.sample(presentationNs: presentationNs, contentScale: 1, dirtyRects: [rect]), of: .screen)
        delivered.append(fixture.sink.lastDirtyRects)
      }

      try deliver(1)
      try deliver(2)
      let reconfigure = Task { @MainActor in try await fixture.capture.update(configuration: .init()) }
      await held.entered.wait()
      try deliver(3)
      try deliver(4)
      held.release()
      try await reconfigure.value
      try deliver(5)
      try deliver(6)

      #expect(delivered == [nil, [rect], nil, nil, nil, [rect]])
    }

    private static func replay(_ history: CaptureHistory, on fixture: CaptureFixture) async throws {
      guard history != .nothing else { return }
      let output = try #require(fixture.target.output)
      output.deliver(try sample(presentationNs: 1, contentScale: 1), of: .screen)
      switch history {
      case .nothing, .aFrame: break
      case .aFrameThenAnIdleCallback: output.deliver(try sample(presentationNs: 2, status: .idle), of: .screen)
      case .aFrameThenACallbackWithoutAPicture:
        output.deliver(try sample(presentationNs: 2, status: .blank), of: .screen)
      case .aFrameThenAReconfigure: try await fixture.capture.update(configuration: .init())
      case .aFrameThenARestart:
        try await fixture.capture.stop()
        try await fixture.start()
      }
    }

    private static func sample(
      presentationNs: Int64, contentScale: Double? = nil, dirtyRects: [CGRect]? = nil,
      status: SCFrameStatus = .complete
    ) throws -> CMSampleBuffer {
      try ScreenSharingCaptureStateMachineTests.screenSample(
        presentationNs: presentationNs, contentScale: contentScale, dirtyRects: dirtyRects, status: status)
    }
  }

  enum CaptureHistory: Sendable {
    case nothing, aFrame, aFrameThenAnIdleCallback, aFrameThenACallbackWithoutAPicture, aFrameThenAReconfigure
    case aFrameThenARestart
  }
#endif
