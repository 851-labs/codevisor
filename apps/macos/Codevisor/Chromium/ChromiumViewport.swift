import Foundation
import SwiftUI

struct ChromiumViewport: Equatable {
  var width = 390
  var height = 844
  var dpr = 2.0
  var mobile = false
  var touch = false
  var parameters: [String: Any] {
    ["width": width, "height": height, "deviceScaleFactor": dpr, "mobile": mobile]
  }
}

extension ChromiumBrowserModel {
  func setViewport(_ params: [String: Any]) async throws {
    let width = (params["width"] as? NSNumber)?.intValue ?? 0
    let height = (params["height"] as? NSNumber)?.intValue ?? 0
    let dpr = (params["deviceScaleFactor"] as? NSNumber)?.doubleValue ?? 1
    guard (1...10000).contains(width), (1...10000).contains(height), (0.1...8).contains(dpr) else {
      throw ChromiumProtocolError("Viewport must be 1–10000 pixels with DPR 0.1–8")
    }
    let mobile = params["mobile"] as? Bool ?? false
    let touch = params["touch"] as? Bool ?? mobile
    let view = try await readyView()
    var metrics = params
    metrics.removeValue(forKey: "touch")
    let scale = view.setViewportWidth(CGFloat(width), height: CGFloat(height))
    metrics["scale"] = scale
    metrics["dontSetVisibleSize"] = true
    _ = try await view.cdp("Emulation.setDeviceMetricsOverride", metrics)
    _ = try await view.cdp("Emulation.setTouchEmulationEnabled", ["enabled": touch])
    viewport = ChromiumViewport(width: width, height: height, dpr: dpr, mobile: mobile, touch: touch)
  }
  func resetViewport() async throws {
    let view = try await readyView()
    _ = try await view.cdp("Emulation.clearDeviceMetricsOverride")
    _ = try await view.cdp("Emulation.setTouchEmulationEnabled", ["enabled": false])
    view.setViewportWidth(0, height: 0)
    viewport = nil
  }
}

struct ChromiumViewportControls: View {
  @Bindable var model: ChromiumBrowserModel
  @State private var dimensions = ChromiumViewport()
  @State private var failure: String?
  var body: some View {
    HStack(spacing: 10) {
      Menu("Dimensions") {
        Button("Responsive") { apply(ChromiumViewport(width: 1024, height: 768, dpr: 1)) }
        Button("Phone · 390 × 844") { apply(ChromiumViewport(mobile: true, touch: true)) }
        Button("Tablet · 820 × 1180") { apply(ChromiumViewport(width: 820, height: 1180, mobile: true, touch: true)) }
        Button("Desktop · 1440 × 900") { apply(ChromiumViewport(width: 1440, height: 900, dpr: 1)) }
      }.fixedSize()
      TextField("Width", value: $dimensions.width, format: .number.grouping(.never)).frame(width: 50)
      Text("×")
      TextField("Height", value: $dimensions.height, format: .number.grouping(.never)).frame(width: 50)
      Button {
        let width = dimensions.width; dimensions.width = dimensions.height; dimensions.height = width; apply(dimensions)
      } label: {
        Image(systemName: "rotate.right")
      }.help("Rotate viewport")
      Text("DPR")
      TextField("DPR", value: $dimensions.dpr, format: .number).frame(width: 35)
      Toggle("Mobile", isOn: $dimensions.mobile).onChange(of: dimensions.mobile) { _, value in
        dimensions.touch = value; apply(dimensions)
      }
      Toggle("Touch", isOn: $dimensions.touch).onChange(of: dimensions.touch) { _, _ in apply(dimensions) }
      Spacer(minLength: 0)
      Button("Reset") { Task { do { try await model.resetViewport() } catch { failure = error.localizedDescription } } }
    }
    .font(.callout)
    .textFieldStyle(.roundedBorder)
    .onSubmit { apply(dimensions) }
    .padding(8)
    .background(.bar)
    .onAppear { dimensions = model.viewport ?? dimensions }
    .onChange(of: model.viewport) { _, value in if let value { dimensions = value } }
    .alert("Couldn’t Resize Browser", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }))
    {
    } message: {
      Text(failure ?? "")
    }
  }
  private func apply(_ value: ChromiumViewport) {
    dimensions = value
    Task {
      do { var params = value.parameters; params["touch"] = value.touch; try await model.setViewport(params) } catch {
        failure = error.localizedDescription
      }
    }
  }
}
