import CodevisorClient
import CodevisorUI
import SwiftUI

/// Every simulator on the Mac, to add, rename and delete. On a Mac it's laid out as the app's
/// settings lists are: a grouped list whose rows keep their actions in a ⋯ menu, New Simulator…
/// under it, and Done in the sheet's footer. On an iPhone or iPad it's an inset grouped list with
/// swipe actions, + in the navigation bar and the system close button.
struct SimulatorManagerSheet: View {
  let model: SimulatorPaneModel
  let done: () -> Void
  @State private var creating = false
  @State private var renaming: ServerSimulatorDevice?
  @State private var name = ""
  @State private var pendingDelete: ServerSimulatorDevice?
  #if os(macOS)
    @Environment(\.theme) private var theme
  #endif

  private var devices: [ServerSimulatorDevice] { SimulatorFamilies.sorted(model.list?.devices ?? []) }

  var body: some View {
    NavigationStack {
      list
        .navigationTitle("Simulators")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(role: .close, action: done) }
            ToolbarItem(placement: .primaryAction) {
              Button("New Simulator", systemImage: "plus") { creating = true }
            }
          }
        #endif
    }
    #if os(macOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SheetFooter {
          Button("Done", action: done).keyboardShortcut(.defaultAction)
        }
      }
      .sheetSize(.list)
      .themedSurface(.sheet)
    #endif
    .sheet(isPresented: $creating) {
      SimulatorCreateSheet(model: model) { creating = false }
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
      "Delete \(pendingDelete?.name ?? "Simulator")?",
      isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
      titleVisibility: .visible,
      presenting: pendingDelete
    ) { device in
      Button("Delete Simulator", role: .destructive) { model.delete([device.udid]) }
    } message: { _ in
      Text("Its apps and data are removed from the Mac.")
    }
  }

  #if os(macOS)
    private var list: some View {
      Form {
        Section {
          if devices.isEmpty {
            Text("No Simulators").foregroundStyle(.secondary).frame(maxWidth: .infinity)
          } else {
            ForEach(devices) { device in row(device) }
          }
        } footer: {
          // Under the list it acts on, trailing, as the settings lists' Add buttons are.
          HStack {
            Spacer(minLength: 0)
            Button {
              creating = true
            } label: {
              Label("New Simulator…", systemImage: "plus")
            }
            .settingsActionTint(theme)
          }
          .font(.body)
        }
      }
      .formStyle(.grouped)
    }

    private func row(_ device: ServerSimulatorDevice) -> some View {
      let deleting = model.deleting.contains(device.udid)
      return HStack(spacing: 10) {
        SimulatorManagerRow(device: device, deleting: deleting)
        Menu {
          actions(for: device)
        } label: {
          Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .settingsActionTint(theme)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(deleting)
        .help("Simulator Actions")
        .accessibilityLabel("Actions for \(device.name)")
      }
      .contextMenu { if !deleting { actions(for: device) } }
    }
  #else
    private var list: some View {
      List {
        ForEach(devices) { device in
          let deleting = model.deleting.contains(device.udid)
          SimulatorManagerRow(device: device, deleting: deleting)
            .swipeActions(allowsFullSwipe: false) {
              if !deleting {
                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = device }
                Button("Rename", systemImage: "pencil") { rename(device) }
              }
            }
            .contextMenu { if !deleting { actions(for: device) } }
        }
      }
      .listStyle(.insetGrouped)
      .overlay {
        if devices.isEmpty {
          ContentUnavailableView {
            Label("No Simulators", systemImage: "iphone")
          } description: {
            Text("Add one to run apps on this Mac.")
          } actions: {
            Button("New Simulator…") { creating = true }
          }
        }
      }
    }
  #endif

  @ViewBuilder private func actions(for device: ServerSimulatorDevice) -> some View {
    Button("Rename…", systemImage: "pencil") { rename(device) }
    Divider()
    Button("Delete…", systemImage: "trash", role: .destructive) { pendingDelete = device }
  }

  private func rename(_ device: ServerSimulatorDevice) {
    name = device.name
    renaming = device
  }
}

/// A simulator in a list: its name, then its OS and whether it's running or being deleted.
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
