#if os(macOS)
  import AppKit
  import CodevisorCore
  import Testing

  @testable import CodevisorUI

  @MainActor
  @Suite("Inline plugin app context menu")
  struct PluginAppContextMenuTests {
    private func menu(withCopy: Bool) -> NSMenu {
      let menu = NSMenu()
      for title in ["Look Up “Grafana”", "Translate “Grafana”", "Search with Google"] {
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
      }
      if withCopy {
        let copy = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copy.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopy")
        menu.addItem(copy)
      }
      for title in ["Share…", "Speech", "Services"] {
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
      }
      return menu
    }

    private func opened(_ menu: NSMenu) throws -> [String] {
      let webView = try #require(PluginAppWebController().webView as? PluginAppNativeWebView)
      webView.contextActions = [PluginAppContextAction(title: "Block Grafana…", systemImage: "hand.raised") {}]
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
          eventNumber: 0, clickCount: 1, pressure: 1))
      webView.willOpenMenu(menu, with: event)
      return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test("Over the app's content the menu shows only Block")
    func onlyBlock() throws {
      #expect(try opened(menu(withCopy: false)) == ["Block Grafana…"])
    }

    @Test("Over selected text the menu keeps Copy, then Block")
    func copyThenBlock() throws {
      #expect(try opened(menu(withCopy: true)) == ["Copy", "—", "Block Grafana…"])
    }

    @Test("The app's web view offers no Services, so the system doesn't add them to its menu")
    func noServices() throws {
      let webView = try #require(PluginAppWebController().webView as? PluginAppNativeWebView)

      #expect(webView.validRequestor(forSendType: .string, returnType: nil) == nil)
    }

    @Test("Blocking is offered by plugin name for catalog plugins and not at all for plugins added by address")
    func blockTitle() {
      let catalog = PluginModerationSubject(
        pluginId: "grafana/grafana", name: "Grafana", publisher: "grafana", declaredAgeRating: nil, revision: "1")
      let local = PluginModerationSubject(
        custom: CustomPluginLocation(transport: "http", url: "http://127.0.0.1:4795/mcp", command: nil, args: []),
        name: "Grafana")

      #expect(PluginAppContextAction.blockTitle(for: catalog) == "Block Grafana…")
      #expect(PluginAppContextAction.blockTitle(for: local) == nil)
    }
  }
#endif
