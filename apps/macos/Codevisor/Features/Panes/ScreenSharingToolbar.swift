import CodevisorClient
import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import ScreenSharing
import SwiftUI

struct ScreenSharingToolbar: ToolbarContent {
  @Bindable var store: StoreOf<ScreenSharingViewer>
  let settings: () -> ScreenSharingMachineSettings
  let applySettings: (ScreenSharingMachineSettingsChanges) -> Void

  var body: some ToolbarContent {
    ToolbarItem(id: "screenSharing.mode", placement: .principal) {
      ScreenSharingModePicker(store: store)
    }
    if store.endpoint?.supportsSystemKeys == true {
      ForEach(ScreenSharingSystemKey.allCases, id: \.self) { key in
        ToolbarItem(id: "screenSharing.macControls.\(key.rawValue)", placement: .principal) {
          ScreenSharingSystemKeyButton(store: store, key: key)
        }
      }
    }
    ToolbarItem(id: "screenSharing.display", placement: .primaryAction) {
      ScreenSharingDisplayPicker(store: store)
    }
    ToolbarItem(id: "screenSharing.clipboard", placement: .primaryAction) {
      ScreenSharingClipboardMenu(store: store)
    }
    ToolbarItem(id: "screenSharing.details", placement: .primaryAction) {
      ScreenSharingDetailsButton(store: store).id(ObjectIdentifier(store))
    }
    ToolbarItem(id: "screenSharing.settings", placement: .primaryAction) {
      ScreenSharingMachineSettingsButton(settings: settings, apply: applySettings).id(ObjectIdentifier(store))
    }
  }
}

struct ScreenSharingLeadingControls: View {
  let store: StoreOf<ScreenSharingViewer>

  var body: some View {
    ScreenSharingModePicker(store: store)
    if store.endpoint?.supportsSystemKeys == true {
      ForEach(ScreenSharingSystemKey.allCases, id: \.self) { key in
        ScreenSharingSystemKeyButton(store: store, key: key)
      }
    }
  }
}

struct ScreenSharingTrailingControls: View {
  let store: StoreOf<ScreenSharingViewer>
  let settings: () -> ScreenSharingMachineSettings
  let applySettings: (ScreenSharingMachineSettingsChanges) -> Void

  var body: some View {
    ScreenSharingDisplayPicker(store: store)
    ScreenSharingClipboardMenu(store: store)
    ScreenSharingDetailsButton(store: store).id(ObjectIdentifier(store))
    ScreenSharingMachineSettingsButton(settings: settings, apply: applySettings).id(ObjectIdentifier(store))
  }
}

private struct ScreenSharingModePicker: View {
  @Bindable var store: StoreOf<ScreenSharingViewer>

  var body: some View {
    if store.endpoint?.supportsControl != false {
      Picker("Interaction mode", selection: $store.interactionMode.sending(\.interactionModeChanged)) {
        Label("View", systemImage: "binoculars").labelStyle(.iconOnly)
          .help("View only")
          .tag(ScreenSharingViewer.InteractionMode.view)
        Label("Control", systemImage: "cursorarrow.click.2").labelStyle(.iconOnly)
          .help("Control this Mac")
          .tag(ScreenSharingViewer.InteractionMode.control)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .help(
        "Send mouse, keyboard and app shortcuts to this Mac once you click into it. Control–Option–Escape hands the keyboard back."
      )
    }
  }
}

private struct ScreenSharingDisplayPicker: View {
  let store: StoreOf<ScreenSharingViewer>

  var body: some View {
    if store.displays.count > 1 {
      Picker(
        "Display",
        selection: Binding(
          get: { store.selectedDisplayId ?? store.displays.first?.id ?? "" },
          set: { store.send(.displaySelected($0)) })
      ) {
        ForEach(store.displays) { display in Text(display.name).tag(display.id) }
      }
      .pickerStyle(.menu).labelsHidden().fixedSize()
      .help("Switch to another display of this Mac")
    }
  }
}

private struct ScreenSharingClipboardMenu: View {
  let store: StoreOf<ScreenSharingViewer>

  var body: some View {
    if store.endpoint?.supportsClipboard != false {
      let clipboard = store.endpoint?.clipboard
      Menu {
        Toggle(isOn: Binding(get: { clipboard?.sharing == true }, set: { clipboard?.sharing = $0 })) {
          label("Use Shared Clipboard", "arrow.left.arrow.right")
        }
        .disabled(clipboard == nil)
        Divider()
        Group {
          Button {
            clipboard?.sendLocalClipboard()
          } label: {
            label("Send Clipboard", "arrow.up.doc.on.clipboard")
          }
          Button {
            clipboard?.getRemoteClipboard()
          } label: {
            label("Get Clipboard", "arrow.down.doc")
          }
        }
        .disabled(clipboard?.available != true || clipboard?.busy == true || clipboard?.sharing == true)
      } label: {
        Image(systemName: "doc.on.clipboard")
      }
      .accessibilityLabel("Clipboard")
      .help("Share the clipboard with this machine")
    }
  }

  private func label(_ title: String, _ systemImage: String) -> some View {
    Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
  }
}

private struct ScreenSharingDetailsButton: View {
  let store: StoreOf<ScreenSharingViewer>
  @State private var showDiagnostics = false

  var body: some View {
    Button {
      showDiagnostics.toggle()
    } label: {
      Image(systemName: "info.circle")
    }
    .accessibilityLabel("Connection Details")
    .help("Connection Details")
    .popover(isPresented: $showDiagnostics) { ScreenSharingDetailsPopover(store: store) }
  }
}
