#if os(macOS)
  import AppKit
  import ScreenSharingRigKit

  /// The standard menu bar. The rig runs `NSApplication` by hand, not as a
  /// SwiftUI `App`, so nothing installs one for it, and on macOS the usual
  /// shortcuts (⌘Q, ⌘W, ⌘M, ⌘H, copy and paste in text fields, full screen)
  /// are menu key equivalents. While a machine is under Control the video
  /// surface captures keys first and forwards them to the machine, as the
  /// product does; Control–Option–Escape returns to viewing.
  @MainActor
  enum RigMainMenu {
    /// Posted by View → Toggle Sidebar; the shell flips its split view's column visibility, as its toolbar button does.
    static let toggleSidebar = Notification.Name("RigMainMenu.toggleSidebar")
    /// Posted by View → Reconnect; the selected machine starts its connection over.
    static let reconnect = Notification.Name("RigMainMenu.reconnect")
    /// Posted by View → Forget Password; the selected machine drops its stored VNC password and asks again.
    static let forgetPassword = Notification.Name("RigMainMenu.forgetPassword")

    static func install(appName: String = "Codevisor Screen Sharing Rig") {
      let main = NSMenu()

      let app = submenu(appName, in: main)
      app.addItem(
        withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: "")
      app.addItem(.separator())
      let services = NSMenu(title: "Services")
      app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
      NSApp.servicesMenu = services
      app.addItem(.separator())
      app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
      app.addItem(
        withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
      ).keyEquivalentModifierMask = [.command, .option]
      app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
      app.addItem(.separator())
      app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

      let file = submenu("File", in: main)
      file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

      let edit = submenu("Edit", in: main)
      edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
      edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
      edit.addItem(.separator())
      edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
      edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
      edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
      edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

      let view = submenu("View", in: main)
      view.addItem(withTitle: "Reconnect", action: #selector(RigMenuTarget.reconnect(_:)), keyEquivalent: "r").target =
        RigMenuTarget.shared
      // 851-2315: the selected machine's remote desktop at a pixel per device pixel; reconnects.
      view.addItem(
        withTitle: "Retina Remote Desktop", action: #selector(RigMenuTarget.toggleRetinaDesktop(_:)), keyEquivalent: ""
      ).target = RigMenuTarget.shared
      view.addItem(
        withTitle: "Forget Password", action: #selector(RigMenuTarget.forgetPassword(_:)), keyEquivalent: ""
      ).target = RigMenuTarget.shared
      view.addItem(.separator())
      let sidebar = view.addItem(
        withTitle: "Toggle Sidebar", action: #selector(RigMenuTarget.toggleSidebar(_:)), keyEquivalent: "s")
      sidebar.keyEquivalentModifierMask = [.command, .control]
      sidebar.target = RigMenuTarget.shared
      view.addItem(
        withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
      ).keyEquivalentModifierMask = [.command, .control]

      let window = submenu("Window", in: main)
      window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
      window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
      window.addItem(.separator())
      window.addItem(
        withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
      NSApp.windowsMenu = window

      NSApp.mainMenu = main
    }

    private static func submenu(_ title: String, in main: NSMenu) -> NSMenu {
      let menu = NSMenu(title: title)
      main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
      return menu
    }
  }

  /// Actions the rig handles itself rather than through the responder chain.
  @MainActor
  final class RigMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = RigMenuTarget()
    /// The machine whose view is mounted (only the selected one is).
    var selectedMachineId: String?
    @objc func toggleRetinaDesktop(_ sender: Any?) {
      guard let id = selectedMachineId else { return }
      RigMachineSettings.setRetinaDesktop(!RigMachineSettings.retinaDesktop(id), for: id)
      NotificationCenter.default.post(name: RigMainMenu.reconnect, object: nil)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
      if item.action == #selector(forgetPassword(_:)) {
        // Only a machine whose password lives in the Keychain has one to forget.
        let machine = RigMachine.catalog.first { $0.id == selectedMachineId }
        guard case .vnc(_, _, .keychain) = machine?.connection else { return false }
        return true
      }
      guard item.action == #selector(toggleRetinaDesktop(_:)) else { return true }
      item.state = selectedMachineId.map(RigMachineSettings.retinaDesktop) == true ? .on : .off
      return selectedMachineId != nil
    }
    @objc func forgetPassword(_ sender: Any?) {
      NotificationCenter.default.post(name: RigMainMenu.forgetPassword, object: nil)
    }
    @objc func reconnect(_ sender: Any?) {
      NotificationCenter.default.post(name: RigMainMenu.reconnect, object: nil)
    }
    @objc func toggleSidebar(_ sender: Any?) {
      NotificationCenter.default.post(name: RigMainMenu.toggleSidebar, object: nil)
    }
  }

  /// Per-machine rig settings, in the rig's defaults (the product keeps them on its machine records).
  enum RigMachineSettings {
    static func retinaDesktop(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: "retinaDesktop.\(id)") }
    static func setRetinaDesktop(_ enabled: Bool, for id: String) {
      UserDefaults.standard.set(enabled, forKey: "retinaDesktop.\(id)")
    }
  }
#endif
