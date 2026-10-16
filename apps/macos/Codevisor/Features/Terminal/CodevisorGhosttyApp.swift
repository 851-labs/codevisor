import AppKit
import Foundation
import GhosttyKit
import CodevisorCore
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

  private(set) var app: ghostty_app_t!

  var config: Ghostty.Config

  let surfaces = NSHashTable<Ghostty.SurfaceView>.weakObjects()

  nonisolated let pendingWakeupTick = OSAllocatedUnfairLock(initialState: false)

  static var currentSystemIsDark: Bool?
  private static var runtimeInitialized = false

  static func applySystemAppearance(isDark: Bool) {
    guard currentSystemIsDark != isDark else { return }
    currentSystemIsDark = isDark
    guard runtimeInitialized else { return }
    shared.reloadConfig()
  }

  private init() {
    setenv("GHOSTTY_RESOURCES_DIR", Self.prepareBundledResources(), 1)

    _ = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

    let config = Ghostty.Config(config: Self.buildConfig(systemIsDark: Self.currentSystemIsDark))
    self.config = config

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

  func register(_ view: Ghostty.SurfaceView) {
    surfaces.add(view)
  }

  func unregister(_ view: Ghostty.SurfaceView) {
    surfaces.remove(view)
  }

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

  nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(work)
    } else {
      DispatchQueue.main.async(execute: work)
    }
  }

  nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    let host = hostApp(from: userdata)
    let alreadyPending = host.pendingWakeupTick.withLock { pending -> Bool in
      if pending { return true }
      pending = true
      return false
    }
    guard !alreadyPending else { return }
    DispatchQueue.main.async {
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
    nonisolated(unsafe) let state = state
    let requested: [String] = (0..<mimesLen).compactMap { index in
      mimes?[index].map { String(cString: $0) }
    }
    let textMime = requested.first { textMimes.contains($0) }

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
      guard (textMime != nil && text != nil) || list else {
        return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
      }
      completeClipboardRequest(
        surface, text: textMime == nil ? nil : text, mime: textMime,
        available: list && text != nil ? ["text/plain"] : [], state: state)
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }
  }

  nonisolated static func confirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    let surfaceView = surfaceUserdata(from: userdata)
    nonisolated(unsafe) let state = state
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

    let contentArray = (0..<len).compactMap { i in
      Ghostty.ClipboardContent.from(content: content[i])
    }
    guard !contentArray.isEmpty else { return }

    onMain {
      guard let pasteboard = NSPasteboard.ghostty(location) else { return }

      if !confirm {
        let types = contentArray.compactMap { item in
          NSPasteboard.PasteboardType(mimeType: item.mime)
        }
        pasteboard.declareTypes(types, owner: nil)

        for item in contentArray {
          guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
          pasteboard.setString(item.data, forType: type)
        }
        return
      }

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
