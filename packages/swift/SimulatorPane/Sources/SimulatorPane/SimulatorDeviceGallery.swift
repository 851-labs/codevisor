import CodevisorClient
import SwiftUI

/// Kinds of device, in the order lists show them.
enum SimulatorFamilies {
  static let order = ["iPhone", "iPad", "Apple Watch", "Apple TV", "Apple Vision"]

  /// One list without per-kind sections: iPhones first, then iPads and so on, each kind in the
  /// order simctl lists it.
  static func sorted(_ devices: [ServerSimulatorDevice]) -> [ServerSimulatorDevice] {
    let rank = { (family: String) in order.firstIndex(of: family) ?? order.count }
    return devices.enumerated()
      .sorted { lhs, rhs in
        let left = rank(lhs.element.deviceType.productFamily), right = rank(rhs.element.deviceType.productFamily)
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element)
  }
}

/// A pane with no device yet: the Mac's simulators as cards to pick from.
struct SimulatorDeviceGallery: View {
  let model: SimulatorPaneModel
  @State private var creating = false

  var body: some View {
    let devices = model.list?.devices ?? []
    if devices.isEmpty {
      ContentUnavailableView {
        Label("No Simulators", systemImage: "iphone")
      } description: {
        Text("This Mac has no simulators yet.")
      } actions: {
        Button("New Simulator…") { creating = true }.buttonStyle(.glassProminent)
      }
      .sheet(isPresented: $creating) { SimulatorCreateSheet(model: model) { creating = false } }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text("Choose a Simulator").font(.title2.weight(.semibold))
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)], spacing: 12) {
            ForEach(SimulatorFamilies.sorted(devices)) { device in
              SimulatorDeviceCard(device: device) { model.choose(device.udid) }
            }
          }
          Button("New Simulator…", systemImage: "plus") { creating = true }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .sheet(isPresented: $creating) { SimulatorCreateSheet(model: model) { creating = false } }
    }
  }
}

struct SimulatorDeviceCard: View {
  let device: ServerSimulatorDevice
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      VStack(spacing: 10) {
        Image(systemName: SimulatorArtwork.symbol(family: device.deviceType.productFamily))
          .font(.system(size: 34))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .frame(height: 44)
        VStack(spacing: 2) {
          Text(device.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
          HStack(spacing: 4) {
            if device.isBooted { Circle().fill(.green).frame(width: 6, height: 6) }
            Text(device.runtime.name).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .padding(4)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.roundedRectangle(radius: 16))
    .accessibilityLabel("\(device.name), \(device.runtime.name)\(device.isBooted ? ", running" : "")")
  }
}

/// Name, device type and OS for a new simulator.
struct SimulatorCreateSheet: View {
  let model: SimulatorPaneModel
  /// Whether the pane switches to the new simulator (it doesn't from Manage Simulators).
  var showsCreated = true
  let done: () -> Void
  @State private var name = ""
  @State private var deviceType = ""
  @State private var runtime = ""

  private var deviceTypes: [ServerSimulatorDeviceType] { model.list?.deviceTypes ?? [] }
  private var runtimes: [ServerSimulatorRuntime] {
    (model.list?.runtimes ?? []).filter { $0.deviceTypeIdentifiers.contains(deviceType) }
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name, prompt: Text(deviceTypes.first { $0.identifier == deviceType }?.name ?? "Name"))
        Picker("Device", selection: $deviceType) {
          ForEach(SimulatorFamilies.order, id: \.self) { family in
            let types = deviceTypes.filter { $0.productFamily == family }
            if !types.isEmpty {
              Section(family) {
                ForEach(types) { Text($0.name).tag($0.identifier) }
              }
            }
          }
        }
        Picker("OS Version", selection: $runtime) {
          ForEach(runtimes) { Text($0.name).tag($0.identifier) }
        }
        .disabled(runtimes.isEmpty)
      }
      .formStyle(.grouped)
      .navigationTitle("New Simulator")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            let typeName = deviceTypes.first { $0.identifier == deviceType }?.name ?? "Simulator"
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            model.create(
              name: trimmed.isEmpty ? typeName : trimmed, deviceType: deviceType, runtime: runtime,
              show: showsCreated)
            done()
          }
          .disabled(deviceType.isEmpty || runtime.isEmpty)
        }
      }
    }
    .frame(minWidth: 380, minHeight: 260)
    .onAppear {
      if deviceType.isEmpty {
        deviceType =
          model.device?.deviceType.identifier
          ?? deviceTypes.first { $0.productFamily == "iPhone" }?.identifier ?? deviceTypes.first?.identifier ?? ""
      }
    }
    .onChange(of: deviceType, initial: true) {
      if !runtimes.contains(where: { $0.identifier == runtime }) { runtime = runtimes.last?.identifier ?? "" }
    }
  }
}
