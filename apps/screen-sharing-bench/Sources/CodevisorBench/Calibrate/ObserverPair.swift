import ScreenCaptureKit
import ScreenSharingBench

@MainActor
struct ObserverPair {
  struct Logs {
    let barcode: [BenchObservation]
    let full: [BenchObservation]
    let continuousMinusAbsoluteNs: Int64

    var agreement: BenchObserverAgreement {
      BenchObserverAgreement(BenchObservedVersions(barcode), BenchObservedVersions(full))
    }
  }

  private let barcode: ScreenObserver
  private let full: ScreenObserver

  static func start(display: SCDisplay, layout: BenchBarcodeLayout) async throws -> ObserverPair {
    let barcode = try await ScreenObserver.start(display: display, region: .barcode, layout: layout)
    let full = try await ScreenObserver.start(display: display, region: .full, layout: layout)
    return ObserverPair(barcode: barcode, full: full)
  }

  var sources: [String] {
    [barcode.source, full.source]
  }

  func stop() async throws -> Logs {
    Logs(
      barcode: try await barcode.stop(), full: try await full.stop(),
      continuousMinusAbsoluteNs: barcode.continuousMinusAbsoluteNs)
  }
}
