import Testing
@testable import CodevisorUI

@Suite("Diff scroll consumption")
struct DiffScrollConsumptionPolicyTests {
  @Test("Content that fits never owns vertical scrolling")
  func fittingContentDoesNotConsume() {
    #expect(
      !DiffScrollConsumptionPolicy.canConsume(
        contentDelta: 10,
        offset: 0,
        contentLength: 200,
        viewportLength: 200
      )
    )
  }

  @Test("The top boundary hands upward scrolling to the transcript")
  func topBoundaryHandsOff() {
    #expect(
      !DiffScrollConsumptionPolicy.canConsume(
        contentDelta: -10,
        offset: 0,
        contentLength: 1_000,
        viewportLength: DiffViewportMetrics.maximumHeight
      )
    )
    #expect(
      DiffScrollConsumptionPolicy.canConsume(
        contentDelta: 10,
        offset: 0,
        contentLength: 1_000,
        viewportLength: DiffViewportMetrics.maximumHeight
      )
    )
  }

  @Test("The bottom boundary hands downward scrolling to the transcript")
  func bottomBoundaryHandsOff() {
    let viewport = DiffViewportMetrics.maximumHeight
    let offset = 1_000 - viewport
    #expect(
      DiffScrollConsumptionPolicy.canConsume(
        contentDelta: -10,
        offset: offset,
        contentLength: 1_000,
        viewportLength: viewport
      )
    )
    #expect(
      !DiffScrollConsumptionPolicy.canConsume(
        contentDelta: 10,
        offset: offset,
        contentLength: 1_000,
        viewportLength: viewport
      )
    )
  }
}
