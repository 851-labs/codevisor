import CodevisorClient
import SwiftUI

/// A Simulator pane: the chosen device front and center. Its controls live in the toolbar
/// (`SimulatorPaneToolbar`), which the hosting app shows while this pane is active.
public struct SimulatorPaneView: View {
  let model: SimulatorPaneModel
  /// Saves or shares a screenshot (PNG) from the Mac's action bar.
  let onScreenshot: (Data, String) -> Void

  public init(model: SimulatorPaneModel, onScreenshot: @escaping (Data, String) -> Void = { _, _ in }) {
    self.model = model
    self.onScreenshot = onScreenshot
  }

  public var body: some View {
    @Bindable var model = model
    ZStack {
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    #if os(macOS)
      // The device's controls sit in the bottom safe area, as the chat composer does, so the
      // device fits above them. An iPhone or iPad uses its bottom toolbar instead.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let device = model.runningDevice {
          SimulatorActionBar(model: model, device: device, onScreenshot: onScreenshot)
          .padding(.top, 8)
          .padding(.bottom, 12)
        }
      }
    #endif
    .sheet(isPresented: $model.managingSimulators) {
      SimulatorManagerSheet(model: model) { model.managingSimulators = false }
    }
    // Settings belong to the running device they were opened for.
    .onChange(of: model.udid) { model.showsSettings = false }
    .onChange(of: model.device?.isBooted) { _, booted in
      if booted != true { model.showsSettings = false }
    }
    .onAppear { model.appeared() }
    .onDisappear { model.disappeared() }
    .alert(
      "Simulator", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
      presenting: model.alert
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { message in
      Text(message)
    }
  }

  @ViewBuilder private var content: some View {
    if model.list == nil {
      switch model.listState {
      case .failed(let message):
        ContentUnavailableView {
          Label("Simulators Unavailable", systemImage: "iphone.slash")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") { Task { await model.refresh() } }
        }
      default:
        ProgressView()
      }
    } else if let device = model.device {
      if let activity = model.activity {
        SimulatorStatusView(device: device, model: model) {
          ProgressView(activity).controlSize(.small)
        }
      } else if device.isBooted {
        SimulatorDeviceCanvas(model: model, device: device)
      } else {
        SimulatorStatusView(device: device, model: model) {
          if device.isShutdown {
            Button("Start") { model.perform(.boot) }
              .buttonStyle(.glassProminent)
              .controlSize(.large)
              .keyboardShortcut(.defaultAction)
          } else {
            ProgressView("\(device.state)…").controlSize(.small)
          }
        }
      }
    } else if model.activity != nil {
      ProgressView(model.activity ?? "")
    } else {
      SimulatorDeviceChooser(model: model)
    }
  }
}

/// A device that isn't running: its silhouette, name and what to do next.
struct SimulatorStatusView<Accessory: View>: View {
  let device: ServerSimulatorDevice
  let model: SimulatorPaneModel
  @ViewBuilder let accessory: Accessory

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: SimulatorArtwork.symbol(family: device.deviceType.productFamily))
        .font(.system(size: 72, weight: .regular))
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.hierarchical)
        .padding(.bottom, 6)
      VStack(spacing: 4) {
        Text(device.name).font(.title2.weight(.semibold))
        Text("\(device.runtime.name) Simulator").font(.callout).foregroundStyle(.secondary)
      }
      accessory.padding(.top, 6)
    }
    .multilineTextAlignment(.center)
    .padding(32)
  }
}
