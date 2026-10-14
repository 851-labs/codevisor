import AppKit
import Foundation
import Observation
import SwiftUI
import CodevisorCore
import os
import CodevisorUI

@MainActor
@Observable
final class TerminalPane: Pane, Identifiable {
  let id: UUID
  let kind: PaneKind = .terminal
  let descriptor: TerminalLaunchDescriptor

  @ObservationIgnored var onGroupCommand: ((PaneGroupCommand) -> Void)?

  @ObservationIgnored var onFocusChanged: ((Bool) -> Void)?
  @ObservationIgnored var onContentAttached: (() -> Void)?

  @ObservationIgnored private var _surface: (any TerminalSurface)?

  private(set) var surfaceGeneration = 0

  init(context: PaneContext) {
    self.id = context.paneId
    self.descriptor = TerminalLaunchDescriptor.make(
      session: context.session,
      project: context.project,
      machine: context.machine,
      serverConfig: context.resolveServerConfig?(),
      terminalKey: context.terminalKey,
      workspaceRootDirectory: context.workspaceRootDirectory
    )
  }

  func ensureSurface() -> any TerminalSurface {
    if let surface = _surface { return surface }
    let surface = TerminalRuntime.factory.makeSurface(descriptor: descriptor)
    surface.onRestartRequest = { [weak self] in self?.restart() }
    surface.onPaneCommand = { [weak self] command in self?.onGroupCommand?(command) }
    surface.onFocusChanged = { [weak self] focused in self?.onFocusChanged?(focused) }
    _surface = surface
    return surface
  }

  func restart() {
    _surface?.terminate()
    _surface = nil

    Task {
      await deleteServerShell()
      surfaceGeneration += 1
    }
  }

  func makeView() -> AnyView {
    AnyView(TerminalPaneView(pane: self))
  }

  func focus() {
    guard let view = _surface?.nsView, let window = view.window,
      window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil
    else { return }
    window.makeFirstResponder(view)
  }

  func visibilityChanged(_ visible: Bool) {
    if !visible {
      _surface?.setFocused(false)
    }
    _surface?.setVisible(visible)
  }

  func willDelete() async {
    _surface?.terminate()
    _surface = nil
    await deleteServerShell()
  }

  func detach() {
    _surface?.terminate()
    _surface = nil
  }

  private func deleteServerShell() async {
    let config = descriptor.serverConfig
    var request = URLRequest(
      url: config.baseURL
        .appendingPathComponent("v1/terminals/session")
        .appendingPathComponent(descriptor.terminalKey)
    )
    request.httpMethod = "DELETE"
    if let token = config.bearerToken, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    do {
      let transport = config.requestTransport ?? URLSessionRequestTransport(session: .shared)
      _ = try await transport.data(for: request)
    } catch {
      Log.terminal.debug(
        "server shell delete failed for \(self.descriptor.terminalKey, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }
}

struct TerminalPaneView: View {
  @Environment(\.theme) private var theme
  var pane: TerminalPane

  var body: some View {
    TerminalSurfaceView(pane: pane)
      .id(pane.surfaceGeneration)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.terminalBackground)
  }
}
