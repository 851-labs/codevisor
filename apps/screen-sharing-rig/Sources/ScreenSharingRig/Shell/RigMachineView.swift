#if os(macOS)
  import CodevisorClient
  import CodevisorCoreMac
  import ComposableArchitecture
  import Foundation
  import ScreenSharing
  import ScreenSharingRigKit
  import Security
  import SwiftUI

  /// One machine, viewed exactly as the product's Screen Sharing pane views
  /// it: the product's `ScreenSharingViewer` feature (discovery, the control
  /// lease, clipboard, diagnostics) over the product's backend for it. The rig
  /// only supplies a server machine's token.
  @MainActor
  @Observable
  final class RigMachineModel {
    let machine: RigMachine
    private(set) var store: StoreOf<ScreenSharingViewer>?
    /// What the rig is doing before the store exists (token, first contact), or why that failed.
    private(set) var preparing: String?
    private(set) var failure: String?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var visible = false

    init(machine: RigMachine) { self.machine = machine }

    func appeared() {
      visible = true
      if let store { store.send(.paneAppeared) } else if prepareTask == nil { prepare() }
    }

    func disappeared() {
      visible = false
      store?.send(.paneDisappeared)
    }

    /// A failed pane starts over from the token, so a rotated token is picked up too.
    func retry() {
      store?.send(.paneClosed)
      store = nil
      prepare()
    }

    private func prepare() {
      prepareTask?.cancel()
      failure = nil
      let machine = machine
      prepareTask = Task { [weak self] in
        do {
          let backend = try await Self.backend(machine) { self?.preparing = $0 }
          guard let self, !Task.isCancelled else { return }
          self.preparing = nil
          self.prepareTask = nil
          let store = Store(initialState: ScreenSharingViewer.State()) {
            ScreenSharingViewer()
          } withDependencies: {
            $0[ScreenSharingViewerBackend.self] = backend
          }
          self.store = store
          if self.visible { store.send(.paneAppeared) }
        } catch {
          guard let self, !Task.isCancelled else { return }
          self.preparing = nil
          self.prepareTask = nil
          self.failure = error.localizedDescription
        }
      }
    }

    /// The backend the product's pane would use for this machine: `.native`
    /// over its Codevisor server, or `.vnc` straight to a VNC server.
    private static func backend(
      _ machine: RigMachine, progress: @MainActor (String) -> Void
    ) async throws -> ScreenSharingViewerBackend {
      switch machine.connection {
      case .vnc(let host, let port, let password):
        return .vnc(displayId: RigMachine.vncDisplayId(port: port)) {
          try await VNCConnection.open(host: host, port: port, password: password)
        }
      case .server(let url, let sshTarget):
        let client: CodevisorServerClient
        do {
          client = try await Self.client(machine.id, url: url, sshTarget: sshTarget, fresh: false, progress: progress)
        } catch CodevisorServerClientError.httpStatus(401, _) {
          // The machine rotated its token: ask it again, once.
          client = try await Self.client(machine.id, url: url, sshTarget: sshTarget, fresh: true, progress: progress)
        }
        return .native(client: client, workspaceId: UUID(), paneId: UUID())
      }
    }

    /// A client whose token the server accepted (a `capabilities` round trip). `fresh` skips the Keychain.
    private static func client(
      _ id: String, url: URL, sshTarget: String, fresh: Bool, progress: @MainActor (String) -> Void
    ) async throws -> CodevisorServerClient {
      var token = fresh ? nil : RigMachineTokenStore.read(id)
      if token == nil {
        progress("Asking \(sshTarget) for its token…")
        let fetched = try await RigMachineTokenStore.fetch(sshTarget: sshTarget)
        RigMachineTokenStore.save(fetched, for: id)
        token = fetched
      }
      progress("Connecting to \(url.host() ?? id)…")
      let client = CodevisorServerClient(config: CodevisorServerConfig(baseURL: url, bearerToken: token))
      _ = try await client.screenSharing(
        ServerScreenSharingRequest(operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID()))
      return client
    }
  }

  struct RigMachineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// Machine tokens in the login Keychain, keyed by catalog id; fetched with
  /// `ssh <target> codevisor token` when missing or rejected.
  enum RigMachineTokenStore {
    private static let service = "com.codevisor.ScreenSharingRig.machine-token"

    static func read(_ id: String) -> String? {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var item: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
        return nil
      }
      return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for id: String) {
      let match: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: id,
      ]
      SecItemDelete(match as CFDictionary)
      var add = match
      add[kSecValueData as String] = Data(token.utf8)
      add[kSecAttrLabel as String] = "Codevisor Screen Sharing Rig: \(id) token"
      SecItemAdd(add as CFDictionary, nil)
    }

    static func fetch(sshTarget: String) async throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = RigMachine.tokenCommandArguments(sshTarget: sshTarget)
      let output = Pipe()
      let errors = Pipe()
      process.standardOutput = output
      process.standardError = errors
      process.standardInput = FileHandle.nullDevice
      return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
          let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if process.terminationStatus == 0, !token.isEmpty {
            continuation.resume(returning: token)
          } else {
            continuation.resume(
              throwing: RigMachineError(
                "ssh \(sshTarget) codevisor token failed: \(message.isEmpty ? "exit \(process.terminationStatus)" : message)"
              ))
          }
        }
        do { try process.run() } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// The product pane's layout: lease and clipboard messages over the video,
  /// progress while connecting, the failure and Retry in place.
  struct RigMachineView: View {
    let model: RigMachineModel

    var body: some View {
      Group {
        if let store = model.store {
          if store.phase == .failed {
            failure(store.message) { model.retry() }
          } else {
            connection(store)
          }
        } else if let message = model.failure {
          failure(message) { model.retry() }
        } else {
          progress(model.preparing ?? "Connecting to \(model.machine.name)…")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle(model.machine.name)
      .navigationSubtitle(model.machine.detail)
      .toolbar {
        if let store = model.store { RigScreenSharingToolbar(store: store) }
      }
      // View → Reconnect (⌘R): only the selected machine's view is mounted, so it is the one that reconnects.
      .onReceive(NotificationCenter.default.publisher(for: RigMainMenu.reconnect)) { _ in model.retry() }
      .onAppear { model.appeared() }
      .onDisappear { model.disappeared() }
    }

    private func failure(_ message: String?, retry: @escaping () -> Void) -> some View {
      VStack(spacing: 12) {
        Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
        if let message {
          Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        Button("Retry", action: retry)
      }
      .padding(24)
    }

    private func progress(_ message: String) -> some View {
      VStack(spacing: 12) {
        ProgressView().controlSize(.small)
        Text(message)
      }
      .padding(24)
    }

    private func connection(_ store: StoreOf<ScreenSharingViewer>) -> some View {
      VStack(spacing: 0) {
        if let message = store.lease?.message { banner(message) }
        if let message = store.endpoint?.clipboard?.message { banner(message) }
        ZStack {
          if let endpoint = store.endpoint {
            RigEndpointView(endpoint: endpoint)
          }
          if store.phase != .viewing {
            progress(
              store.phase == .reconnecting
                ? "Reconnecting to \(model.machine.name)…" : "Connecting to \(model.machine.name)…")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }

    private func banner(_ message: String) -> some View {
      Text(message).font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
    }
  }

  /// The endpoint's video surface on the native window background, as the product's system theme shows it.
  private struct RigEndpointView: NSViewRepresentable {
    let endpoint: ScreenSharingViewerEndpoint
    func makeNSView(context: Context) -> NSView { endpoint.view }
    func updateNSView(_ nsView: NSView, context: Context) { endpoint.letterbox(.windowBackgroundColor) }
  }
#endif
