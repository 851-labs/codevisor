import AppKit
import CodevisorUI
import SwiftUI

struct ChromiumBrowserZoomControls: View {
  @Bindable var model: ChromiumBrowserModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      zoomButton("Zoom Out (⌘−)", symbol: "minus", command: .zoomOut)
        .disabled(!model.canZoomOut)
      Button {
        model.zoom(.reset)
      } label: {
        Text("\(model.zoomPercent)%")
          .font(.system(size: NSFont.systemFontSize, weight: .medium).monospacedDigit())
          .contentTransition(.numericText(value: Double(model.zoomPercent)))
          .animation(Motion.quick(reduceMotion: reduceMotion), value: model.zoomPercent)
          .frame(width: 50, height: 30)
      }
      .buttonStyle(ZoomButtonStyle(shape: Capsule()))
      .disabled(!model.canResetZoom)
      .help("Reset Zoom (⌘0)")
      .accessibilityLabel("Zoom \(model.zoomPercent)%, reset zoom")
      zoomButton("Zoom In (⌘+)", symbol: "plus", command: .zoomIn)
        .disabled(!model.canZoomIn)
    }
    // Native toolbar groups are 36pt tall, with 30pt hover targets inset 3pt.
    .padding(3)
    .fixedSize()
    .glassEffect(.regular.interactive(), in: .capsule)
  }

  private func zoomButton(_ title: String, symbol: String, command: BrowserZoomCommand) -> some View {
    Button {
      model.zoom(command)
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .regular))
        .frame(width: 30, height: 30)
    }
    .buttonStyle(ZoomButtonStyle(shape: Circle()))
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct ZoomButtonStyle<S: Shape>: ButtonStyle {
  let shape: S

  func makeBody(configuration: Configuration) -> some View {
    ZoomButtonBody(configuration: configuration, shape: shape)
  }
}

private struct ZoomButtonBody<S: Shape>: View {
  let configuration: ButtonStyleConfiguration
  let shape: S
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  var body: some View {
    configuration.label
      .foregroundStyle(.primary)
      .background(.primary.opacity(highlightOpacity), in: shape)
      .contentShape(shape)
      .contentShape(.focusEffect, shape)
      .opacity(isEnabled ? 1 : 0.35)
      .animation(.easeOut(duration: 0.12), value: hovering)
      .onHover { hovering = $0 }
  }

  private var highlightOpacity: Double {
    guard isEnabled else { return 0 }
    return configuration.isPressed ? 0.20 : (hovering ? 0.12 : 0)
  }
}
