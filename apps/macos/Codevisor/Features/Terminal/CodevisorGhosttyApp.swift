//  CodevisorGhosttyApp: the process-wide libghostty runtime host.
//
//  Replaces the role of upstream Ghostty's `Ghostty.App` (.repos/ghostty/
//  macos/Sources/Ghostty/Ghostty.App.swift) for Codevisor's embedding: it owns the
//  single `ghostty_app_t`, registers the runtime callbacks (clipboard, wakeup,
//  action dispatch), and manages Codevisor's theme-driven config. Callback and
//  action-handler bodies are copied from upstream near-verbatim; the action
//  switch only implements per-surface actions Codevisor supports — window/tab/
//  split/app-management actions return false (unhandled).

import AppKit
import Foundation
import GhosttyKit
import CodevisorCore
import CodevisorTheming
import SwiftUI
import os

@MainActor
final class CodevisorGhosttyApp {
  static let shared = CodevisorGhosttyApp()

  private static let ghosttyDefaultFontSize: Float = 13
  private static let terminalFontScale: Float = 0.9
  static var terminalFontSize: Float {
    ghosttyDefaultFontSize * terminalFontScale
  }

  /// The single ghostty app instance shared by all surfaces. Implicitly
  /// unwrapped because `self` must be passed as the runtime-config userdata
  /// before `ghostty_app_new` can run (same reason upstream's App.app is
  /// optional); it is non-nil for the object's entire visible lifetime.
  private(set) var app: ghostty_app_t!

  /// The app-wide config. Replaced on theme changes and CONFIG_CHANGE actions.
  /// Vendored `Ghostty.SurfaceView` reads this at init for its DerivedConfig.
  var config: Ghostty.Config

  /// Live surface views that receive config updates on theme switches.
  let surfaces = NSHashTable<Ghostty.SurfaceView>.weakObjects()

  /// True while a main-queue app tick is already enqueued. libghostty fires
  /// `wakeup` per renderer/PTY event — hundreds per second under heavy
  /// terminal output — and enqueuing a `ghostty_app_tick` for each floods
  /// the main queue with hops that compete with SwiftUI rendering. One
  /// pending tick drains any number of wakeups; a wakeup that lands during
  /// the tick itself (flag already cleared) enqueues the next one, so no
  /// wakeup is ever lost.
  nonisolated let pendingWakeupTick = OSAllocatedUnfairLock(initialState: false)

  // MARK: - Theme

  /// The active terminal theme. Seeded by ThemedRoot before `prewarm()` runs
  /// (so the first config is already themed) and updated on theme switches.
  /// Static so setting it never instantiates the runtime.
  static var currentTheme: TerminalPalette?
  /// The resolved app appearance. This matters when `currentTheme` is nil:
  /// both system theme slots use nil palettes, but Ghostty still needs a
  /// config reload when the system moves between light and dark.
  static var currentSystemIsDark: Bool?
  /// Flipped at the end of init; applyTheme only reloads a runtime that exists.
  private static var runtimeInitialized = false

  /// Applies a theme (nil = system look): stores it for a not-yet-created
  /// runtime, or rebuilds the live config and pushes it to the app and all
  /// open surfaces.
  static func applyTheme(_ theme: TerminalPalette?, systemIsDark: Bool) {
    let themeChanged = theme != currentTheme
    let systemAppearanceChanged = theme == nil && currentSystemIsDark != systemIsDark
    currentTheme = theme
    currentSystemIsDark = systemIsDark
    guard themeChanged || systemAppearanceChanged else { return }
    guard runtimeInitialized else { return }
    shared.reloadConfig()
  }

  // MARK: - Init

  private init() {
    // Point libghostty at the bundled resources (xterm-ghostty terminfo +
    // shell integration). Must be set BEFORE ghostty_init, which captures it.
    setenv("GHOSTTY_RESOURCES_DIR", Self.prepareBundledResources(), 1)

    _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

    let config = Ghostty.Config(
      config: Self.buildConfig(
        theme: Self.currentTheme,
        systemIsDark: Self.currentSystemIsDark
      ))
    self.config = config

    // Runtime config modeled on upstream Ghostty.App.init (L60-70). The
    // userdata is this host; callbacks resolve it via ghostty_app_userdata,
    // never via `shared` (wakeup can fire while the `shared` static-let is
    // still initializing, and re-entering that dispatch_once traps).
    var runtime_cfg = ghostty_runtime_config_s(
      userdata: Unmanaged.passUnretained(self).toOpaque(),
      supports_selection_clipboard: true,
      wakeup_cb: { userdata in CodevisorGhosttyApp.wakeup(userdata) },
      action_cb: { app, target, action in CodevisorGhosttyApp.action(app!, target: target, action: action) },
      read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
        CodevisorGhosttyApp.readClipboard(
          userdata, location: loc, state: state, mimes: mimes, mimesLen: mimesLen, list: list)
      },
      confirm_read_clipboard_cb: { userdata, confirm, state, request in
        CodevisorGhosttyApp.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request)
      },
      write_clipboard_cb: { userdata, loc, content, len, confirm in
        CodevisorGhosttyApp.writeClipboard(
          userdata, location: loc, content: content, len: len, confirm: confirm)
      },
      close_surface_cb: { userdata, processAlive in
        CodevisorGhosttyApp.closeSurface(userdata, processAlive: processAlive)
      }
    )

    guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
      fatalError("ghostty_app_new returned nil.")
    }
    self.app = app

    ghostty_app_set_focus(app, NSApp.isActive)

    // App-level observers (upstream Ghostty.App.init L84-99). The keyboard
    // one is required for correct input after keyboard-layout changes.
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(keyboardSelectionDidChange(notification:)),
      name: NSTextInputContext.keyboardSelectionDidChangeNotification,
      object: nil)
    center.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive(notification:)),
      name: NSApplication.didBecomeActiveNotification,
      object: nil)
    center.addObserver(
      self,
      selector: #selector(applicationDidResignActive(notification:)),
      name: NSApplication.didResignActiveNotification,
      object: nil)

    ghostty_app_keyboard_changed(app)

    Self.runtimeInitialized = true
  }

  // MARK: - Surface registry

  func register(_ view: Ghostty.SurfaceView) {
    surfaces.add(view)
  }

  func unregister(_ view: Ghostty.SurfaceView) {
    surfaces.remove(view)
  }

  // MARK: - App operations

  func appTick() {
    ghostty_app_tick(app)
  }

  @objc private func keyboardSelectionDidChange(notification: NSNotification) {
    ghostty_app_keyboard_changed(app)
  }

  @objc private func applicationDidBecomeActive(notification: NSNotification) {
    ghostty_app_set_focus(app, true)
  }

  @objc private func applicationDidResignActive(notification: NSNotification) {
    ghostty_app_set_focus(app, false)
  }

  // MARK: - Userdata resolution (upstream Ghostty.App L461-477)

  nonisolated static func hostApp(from userdata: UnsafeMutableRawPointer?) -> CodevisorGhosttyApp {
    Unmanaged<CodevisorGhosttyApp>.fromOpaque(userdata!).takeUnretainedValue()
  }

  nonisolated private static func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> Ghostty.SurfaceView {
    Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
  }

  nonisolated static func surfaceView(from surface: ghostty_surface_t) -> Ghostty.SurfaceView? {
    guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
    return Unmanaged<Ghostty.SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
  }

  /// Runs UI work on the main actor from a libghostty callback: immediately
  /// when the callback arrived on the main thread (the common case — the
  /// app loop ticks on main), or dispatched when it arrived on another
  /// thread (the renderer fires cell-size/progress actions during a live
  /// resize; upstream Ghostty.App hops these via DispatchQueue.main).
  ///
  /// This replaces blanket `MainActor.assumeIsolated`, which TRAPS on any
  /// off-main callback. Callers must extract all C-pointer payloads
  /// (strings, buffers, config) BEFORE calling — the pointers do not
  /// outlive the callback.
  nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(work)
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  // MARK: - Runtime callbacks (bodies from upstream Ghostty.App L325-442)

  nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    let host = hostApp(from: userdata)
    // Wakeup can be called from any thread; tick on main — but coalesce:
    // all wakeups arriving while one tick is queued collapse into it.
    let alreadyPending = host.pendingWakeupTick.withLock { pending -> Bool in
      if pending { return true }
      pending = true
      return false
    }
    guard !alreadyPending else { return }
    DispatchQueue.main.async {
      // Clear BEFORE ticking so a wakeup fired mid-tick schedules the
      // follow-up tick it asked for.
      host.pendingWakeupTick.withLock { $0 = false }
      host.appTick()
    }
  }

  nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
    let surface = surfaceUserdata(from: userdata)
    onMain {
      NotificationCenter.default.post(
        name: Ghostty.Notification.ghosttyCloseSurface, object: surface,
        userInfo: [
          "process_alive": processAlive
        ])
    }
  }

  /// Terminal clipboard reads name the MIME types they want; Codevisor
  /// serves text, which is all its paste and OSC 52 paths use.
  nonisolated private static let textMimes: Set<String> = ["text/plain", "text/plain;charset=utf-8"]

  nonisolated static func readClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLen: Int,
    list: Bool
  ) -> ghostty_clipboard_read_result_e {
    let surfaceView = surfaceUserdata(from: userdata)
    // libghostty's opaque token for this request. It is handed back exactly once, on the main
    // actor, so ownership moves with the hop and nothing else touches it.
    nonisolated(unsafe) let state = state
    // Copy the requested MIME types before hopping: the pointers die with
    // the callback.
    let requested: [String] = (0..<mimesLen).compactMap { index in
      mimes?[index].map { String(cString: $0) }
    }
    let textMime = requested.first { textMimes.contains($0) }

    // The synchronous result needs the pasteboard, which is main-thread
    // territory. Reads originate from input processing on main in practice;
    // an off-main caller gets the completion dispatched and an optimistic
    // "started" (worst case a paste binding consumes on an empty clipboard)
    // instead of the hard trap `assumeIsolated` used to be.
    guard Thread.isMainThread else {
      onMain {
        guard let surface = surfaceView.surface else { return }
        let text = NSPasteboard.ghostty(location)?.getOpinionatedStringContents()
        completeClipboardRequest(
          surface, text: textMime == nil ? nil : text, mime: textMime,
          available: list && text != nil ? ["text/plain"] : [], state: state)
      }
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    return MainActor.assumeIsolated {
      guard let surface = surfaceView.surface,
        let pasteboard = NSPasteboard.ghostty(location)
      else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
      let text = pasteboard.getOpinionatedStringContents()
      // Nothing text-like to serve (and no listing asked for): report it, so
      // performable paste bindings can pass through to the terminal.
      guard (textMime != nil && text != nil) || list else {
        return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
      }
      completeClipboardRequest(
        surface, text: textMime == nil ? nil : text, mime: textMime,
        available: list && text != nil ? ["text/plain"] : [], state: state)
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }
  }

  /// CODEVISOR NOTE: upstream posts a notification consumed by a dedicated
  /// ClipboardConfirmation window controller. Codevisor shows a plain NSAlert,
  /// preserving the paste-protection semantics in far less code.
  nonisolated static func confirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    let surfaceView = surfaceUserdata(from: userdata)
    // libghostty's opaque token for this request, handed back exactly once on the main actor.
    nonisolated(unsafe) let state = state
    // Copy the would-be completion before hopping: the confirmation is
    // asynchronous and completes with exactly what the user approved.
    var text: String?
    var mime: String?
    if let confirm = confirm?.pointee, let contents = confirm.contents {
      for index in 0..<confirm.contents_len {
        let content = contents[index]
        let contentMime = String(cString: content.mime)
        guard textMimes.contains(contentMime), let data = content.data else { continue }
        text = String(
          decoding: UnsafeRawBufferPointer(start: data, count: content.len), as: UTF8.self)
        mime = contentMime
        break
      }
    }
    let kind = Ghostty.ClipboardRequest.from(request: request)
    let approvedText = text
    let approvedMime = mime

    onMain {
      guard let surface = surfaceView.surface else { return }
      guard let kind else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
      let alert = NSAlert()
      switch kind {
      case .paste:
        alert.messageText = "Warning: Potentially Unsafe Paste"
        alert.informativeText =
          "Pasting this text may be dangerous as it looks like some text will be executed as a command."
      case .osc_52_read:
        alert.messageText = "Authorize Clipboard Access"
        alert.informativeText = "An application is attempting to read from the clipboard."
      case .osc_52_write:
        alert.messageText = "Authorize Clipboard Access"
        alert.informativeText = "An application is attempting to write to the clipboard."
      }
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Cancel")

      if alert.runModal() == .alertFirstButtonReturn {
        completeClipboardRequest(
          surface, text: approvedText, mime: approvedMime, available: [], state: state,
          confirmed: true)
      } else {
        ghostty_surface_deny_clipboard_request(surface, state)
      }
    }
  }

  static func completeClipboardRequest(
    _ surface: ghostty_surface_t,
    text: String?,
    mime: String?,
    available: [String],
    state: UnsafeMutableRawPointer?,
    confirmed: Bool = false
  ) {
    // Everything the completion points at lives only for this call.
    let mimeC = strdup(mime ?? "text/plain")
    let dataC = strdup(text ?? "")
    let availableC = available.map { strdup($0) }
    defer {
      free(mimeC)
      free(dataC)
      availableC.forEach { free($0) }
    }
    var contents: [ghostty_clipboard_content_s] = []
    if text != nil, mime != nil {
      contents.append(
        ghostty_clipboard_content_s(
          mime: mimeC, data: dataC, len: text.map { $0.utf8.count } ?? 0))
    }
    let availablePointers: [UnsafePointer<CChar>?] = availableC.map { $0.map { UnsafePointer($0) } }
    contents.withUnsafeBufferPointer { contentsBuffer in
      availablePointers.withUnsafeBufferPointer { availableBuffer in
        var complete = ghostty_clipboard_complete_s(
          contents: contentsBuffer.baseAddress,
          contents_len: contentsBuffer.count,
          available: availableBuffer.baseAddress,
          available_len: availableBuffer.count,
          confirmed: confirmed,
          remember: false)
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
      }
    }
  }

  nonisolated static func writeClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int,
    confirm: Bool
  ) {
    _ = surfaceUserdata(from: userdata)
    guard let content, len > 0 else { return }

    // Convert the C array to a Swift array BEFORE hopping to main —
    // the content pointers die with the callback.
    let contentArray = (0..<len).compactMap { i in
      Ghostty.ClipboardContent.from(content: content[i])
    }
    guard !contentArray.isEmpty else { return }

    onMain {
      guard let pasteboard = NSPasteboard.ghostty(location) else { return }

      if !confirm {
        // Declare all types
        let types = contentArray.compactMap { item in
          NSPasteboard.PasteboardType(mimeType: item.mime)
        }
        pasteboard.declareTypes(types, owner: nil)

        // Set data for each type
        for item in contentArray {
          guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
          pasteboard.setString(item.data, forType: type)
        }
        return
      }

      // OSC 52 write confirmation via a plain alert (see confirmReadClipboard note).
      guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }) else { return }
      let alert = NSAlert()
      alert.messageText = "Authorize Clipboard Access"
      alert.informativeText =
        "An application is attempting to write to the clipboard:\n\n\(textPlainContent.data.prefix(256))"
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(textPlainContent.data, forType: .string)
      }
    }
  }
}
