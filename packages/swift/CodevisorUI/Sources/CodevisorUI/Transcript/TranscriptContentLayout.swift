import Observation
import SwiftUI

/// Reports the geometry SwiftUI actually placed, rather than probing a second
/// layout that can still describe the previous contents of a native host.
@MainActor
@Observable
public final class TranscriptContentLayoutObserver {
  public struct Measurement: Equatable, Sendable {
    public let generation: UInt64
    public let request: UInt64
    public let size: CGSize
  }

  public private(set) var request: UInt64 = 0
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored public var onLayout: ((CGSize) -> Void)?

  public init() {}

  public func install(_ content: AnyView) -> AnyView {
    generation &+= 1
    return AnyView(TranscriptContentLayout(content: content, observer: self, generation: generation))
  }

  public func invalidate() {
    request &+= 1
  }

  fileprivate func report(_ measurement: Measurement) {
    guard measurement.generation == generation, measurement.request == request,
      measurement.size.width.isFinite, measurement.size.width > 1,
      measurement.size.height.isFinite, measurement.size.height >= 0
    else { return }
    onLayout?(measurement.size)
  }
}

private struct TranscriptContentLayout: View {
  let content: AnyView
  let observer: TranscriptContentLayoutObserver
  let generation: UInt64

  var body: some View {
    let request = observer.request
    content
      // The virtual row may still have its old or estimated height. Its
      // contents must resolve their natural height independently of it.
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: TranscriptContentLayoutObserver.Measurement.self) { geometry in
        .init(generation: generation, request: request, size: geometry.size)
      } action: { measurement in
        observer.report(measurement)
      }
      .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
  }
}
