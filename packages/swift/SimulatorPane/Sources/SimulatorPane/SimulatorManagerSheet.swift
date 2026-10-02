import CodevisorClient
import SwiftUI

/// Every simulator on the Mac, to add, rename and delete. On a Mac it's the app's usual managed
/// list (selection, a + − bar, right-click actions, Delete key); on an iPhone or iPad, swipe to
/// delete and + in the toolbar.
struct SimulatorManagerSheet: View {
  let model: SimulatorPaneModel
  let done: () -> Void
  @State private var selection = Set<String>()
  @State private var creating = false
  @State private var renaming: ServerSimulatorDevice?
  @State private var name = ""
  @State private var pendingDelete: [ServerSimulatorDevice] = []

  private var devices: [ServerSimulatorDevice] { model.list?.devices ?? [] }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        list
        #if os(macOS)
          Divider()
          addRemoveBar
        #endif
      }
      .navigationTitle("Simulators")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
        #if os(iOS)
          ToolbarItem(placement: .primaryAction) {
            Button("New Simulator", systemImage: "plus") { creating = true }
          }
        #endif
      }
    }
    #if os(macOS)
      .frame(minWidth: 460, idealWidth: 480, minHeight: 440, idealHeight: 520)
    #endif
    .sheet(isPresented: $creating) {
      SimulatorCreateSheet(model: model, showsCreated: false) { creating = false }
    }
    .alert(
      "Rename Simulator",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
      presenting: renaming
    ) { device in
      TextField("Name", text: $name)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { model.rename(device.udid, to: name) }
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
      titleVisibility: .visible
    ) {
      Button(pendingDelete.count == 1 ? "Delete Simulator" : "Delete Simulators", role: .destructive) {
        let udids = Set(pendingDelete.map(\.udid))
        selection.subtract(udids)
        model.delete(udids)
      }
    } message: {
      Text(
        pendingDelete.count == 1
          ? "Its apps and data are removed from the Mac." : "Their apps and data are removed from the Mac.")
    }
    // A device that's gone (deleted here or elsewhere) can't stay selected.
    .onChange(of: devices.map(\.udid)) { _, udids in selection.formIntersection(udids) }
  }

  private var list: some View {
    List(selection: $selection) {
      let sorted = SimulatorFamilies.sorted(devices)
      ForEach(sorted) { device in
        SimulatorManagerRow(device: device, deleting: model.deleting.contains(device.udid))
          .tag(device.udid)
      }
      .onDelete { offsets in pendingDelete = offsets.map { sorted[$0] } }
    }
    .contextMenu(forSelectionType: String.self) { udids in
      actions(for: devices.filter { udids.contains($0.udid) })
    }
    #if os(macOS)
      .listStyle(.inset)
      .onDeleteCommand { requestDelete(selection) }
    #endif
    .overlay {
      if devices.isEmpty {
        ContentUnavailableView {
          Label("No Simulators", systemImage: "iphone")
        } description: {
          Text("Add one to run apps on this Mac.")
        }
      }
    }
  }

  @ViewBuilder private func actions(for chosen: [ServerSimulatorDevice]) -> some View {
    if chosen.count == 1, let device = chosen.first {
      Button("Rename…", systemImage: "pencil") {
        name = device.name
        renaming = device
      }
    }
    if !chosen.isEmpty {
      Button(
        chosen.count == 1 ? "Delete…" : "Delete \(chosen.count) Simulators…", systemImage: "trash", role: .destructive
      ) {
        pendingDelete = chosen
      }
    }
  }

  #if os(macOS)
    /// The app's add/remove bar under a managed list.
    private var addRemoveBar: some View {
      HStack(spacing: 10) {
        Button {
          creating = true
        } label: {
          Image(systemName: "plus")
        }
        .help("New Simulator")
        .accessibilityLabel("New Simulator")
        Button {
          requestDelete(selection)
        } label: {
          Image(systemName: "minus")
        }
        .disabled(selection.isEmpty)
        .help("Delete Simulator")
        .accessibilityLabel("Delete Simulator")
        Spacer()
      }
      .buttonStyle(.borderless)
      .padding(10)
    }
  #endif

  private func requestDelete(_ udids: Set<String>) {
    pendingDelete = devices.filter { udids.contains($0.udid) }
  }

  private var deleteTitle: String {
    pendingDelete.count == 1
      ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) Simulators?"
  }
}

/// A simulator in the manager: its name, then OS and whether it's running or being deleted.
struct SimulatorManagerRow: View {
  let device: ServerSimulatorDevice
  let deleting: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(device.name).lineLimit(1)
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 8)
      if deleting { ProgressView().controlSize(.small) }
    }
    .opacity(deleting ? 0.5 : 1)
    .accessibilityElement(children: .combine)
  }

  private var detail: String {
    if deleting { return "\(device.runtime.name) · Deleting…" }
    return device.isBooted ? "\(device.runtime.name) · Running" : device.runtime.name
  }
}
