#if os(macOS)
  import AppKit

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
  final class RigMenuTarget: NSObject {
    static let shared = RigMenuTarget()
    @objc func toggleSidebar(_ sender: Any?) {
      NotificationCenter.default.post(name: RigMainMenu.toggleSidebar, object: nil)
    }
  }
#endif
