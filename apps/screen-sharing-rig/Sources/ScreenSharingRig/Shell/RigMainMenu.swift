#if os(macOS)
  import AppKit
  import CodevisorCoreMac
  import ScreenSharingRigKit

  @MainActor
  enum RigMainMenu {
    static let toggleSidebar = Notification.Name("RigMainMenu.toggleSidebar")
    static let reconnect = Notification.Name("RigMainMenu.reconnect")
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

  @MainActor
  final class RigMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = RigMenuTarget()
    var selectedMachineId: String?
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
      if item.action == #selector(forgetPassword(_:)) {
        let machine = RigMachine.catalog.first { $0.id == selectedMachineId }
        guard case .vnc(_, _, .keychain) = machine?.connection else { return false }
        return true
      }
      return true
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

  enum RigMachineSettings {
    static func dynamicResolution(_ id: String) -> Bool {
      resetDynamicResolutionOnce()
      return UserDefaults.standard.object(forKey: "dynamicResolution.\(id)") as? Bool ?? false
    }
    static func setDynamicResolution(_ enabled: Bool, for id: String) {
      resetDynamicResolutionOnce()
      UserDefaults.standard.set(enabled, forKey: "dynamicResolution.\(id)")
    }
    private static func resetDynamicResolutionOnce() {
      let defaults = UserDefaults.standard
      guard !defaults.bool(forKey: "dynamicResolutionResetToOff") else { return }
      for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("dynamicResolution.") {
        defaults.removeObject(forKey: key)
      }
      defaults.set(true, forKey: "dynamicResolutionResetToOff")
    }
    static func highDynamicRange(_ id: String) -> Bool {
      UserDefaults.standard.object(forKey: "highDynamicRange.\(id)") as? Bool ?? false
    }
    static func setHighDynamicRange(_ enabled: Bool, for id: String) {
      UserDefaults.standard.set(enabled, forKey: "highDynamicRange.\(id)")
    }
    static func sound(_ id: String) -> ScreenSharingMachineSettings.Sound {
      .init(
        enabled: UserDefaults.standard.object(forKey: "soundEnabled.\(id)") as? Bool ?? true,
        volume: UserDefaults.standard.object(forKey: "soundVolume.\(id)") as? Double ?? 1)
    }
    static func setSound(_ sound: ScreenSharingMachineSettings.Sound, for id: String) {
      UserDefaults.standard.set(sound.enabled, forKey: "soundEnabled.\(id)")
      UserDefaults.standard.set(sound.volume, forKey: "soundVolume.\(id)")
    }
    static func lastConnected(_ id: String) -> Date? {
      UserDefaults.standard.object(forKey: "lastConnected.\(id)") as? Date
    }
    static func setLastConnected(_ date: Date, for id: String) {
      UserDefaults.standard.set(date, forKey: "lastConnected.\(id)")
    }
  }
#endif
