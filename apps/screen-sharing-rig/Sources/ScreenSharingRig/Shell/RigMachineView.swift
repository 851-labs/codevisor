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
  /// only supplies a server machine's token or a VNC machine's password.
  @MainActor
  @Observable
  final class RigMachineModel {
    let machine: RigMachine
    private(set) var store: StoreOf<ScreenSharingViewer>?
    /// What the rig is doing before the store exists (token, first contact), or why that failed.
    private(set) var preparing: String?
    private(set) var failure: String?
    /// Set while a Keychain-password VNC machine waits for the user to type its password.
    private(set) var passwordPrompt: PasswordPrompt?
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

    /// A failed pane starts over from the token or the stored password, so a
    /// rotated token or a changed password is picked up too.
    func retry() {
      store?.send(.paneClosed)
      store = nil
      prepare()
    }

    /// Connects with the password the user typed; it is kept only once the server accepts it.
    func signIn(password: String, remember: Bool) {
      store?.send(.paneClosed)
      store = nil
      prepare(typed: RigVNCSignIn.Typed(password: password, remember: remember))
    }

    /// Removes this machine's stored VNC password and asks for it again.
    func forgetPassword() {
      guard case .vnc(_, _, .keychain) = machine.connection else { return }
      RigKeychain.vncPasswords.delete(machine.id)
      retry()
    }

    private func prepare(typed: RigVNCSignIn.Typed? = nil) {
      prepareTask?.cancel()
      failure = nil
      passwordPrompt = nil
      let machine = machine
      prepareTask = Task { [weak self] in
        do {
          let backend = try await Self.backend(machine, typed: typed) { self?.preparing = $0 }
          guard let self, !Task.isCancelled else { return }
          self.preparing = nil
          self.prepareTask = nil
          let store = Store(
            initialState: ScreenSharingViewer.State(dynamicResolution: RigMachineSettings.dynamicResolution(machine.id))
          ) {
            ScreenSharingViewer()
          } withDependencies: {
            $0[ScreenSharingViewerBackend.self] = backend
          }
          self.store = store
          if self.visible { store.send(.paneAppeared) }
        } catch let prompt as PasswordPrompt {
          guard let self, !Task.isCancelled else { return }
          self.preparing = nil
          self.prepareTask = nil
          self.passwordPrompt = prompt
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
    /// A Keychain-password machine is signed in first (one handshake), so a
    /// missing or rejected password asks the user instead of failing the pane.
    private static func backend(
      _ machine: RigMachine, typed: RigVNCSignIn.Typed?, progress: @MainActor (String) -> Void
    ) async throws -> ScreenSharingViewerBackend {
      switch machine.connection {
      case .vnc(let host, let port, let source):
        if source == .keychain { progress("Signing in to \(host)…") }
        let outcome = try await RigVNCSignIn.signIn(
          machineId: machine.id, password: source, typed: typed, store: RigKeychain.vncPasswords
        ) { password in
          try await VNCConnection.open(host: host, port: port, password: password).client.close()
        }
        let password: String?
        switch outcome {
        case .signedIn(let accepted): password = accepted
        case .needsPassword(let reason): throw PasswordPrompt(reason: reason)
        }
        return .vnc(
          displayId: RigMachine.vncDisplayId(port: port),
          open: { try await VNCConnection.open(host: host, port: port, password: password) })
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
      var token = fresh ? nil : RigKeychain.machineTokens.read(id)
      if token == nil {
        progress("Asking \(sshTarget) for its token…")
        let fetched = try await RigMachineTokenStore.fetch(sshTarget: sshTarget)
        // Not fatal: without it the next launch asks the machine again.
        try? RigKeychain.machineTokens.save(fetched, for: id)
        token = fetched
      }
      progress("Connecting to \(url.host() ?? id)…")
      let client = CodevisorServerClient(config: CodevisorServerConfig(baseURL: url, bearerToken: token))
      _ = try await client.screenSharing(
        ServerScreenSharingRequest(operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID()))
      return client
    }
  }

  /// Why the rig is asking for a VNC password: nil before the first attempt, else the server's rejection.
  struct PasswordPrompt: Error, Equatable {
    let reason: String?
  }

  struct RigMachineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  /// Fetches a server machine's token (`ssh <target> codevisor token`) when
  /// the Keychain has none or the server rejected it.
  enum RigMachineTokenStore {
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
        } else if let prompt = model.passwordPrompt {
          RigVNCPasswordForm(machine: model.machine, prompt: prompt) { model.signIn(password: $0, remember: $1) }
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
        if let store = model.store { RigScreenSharingToolbar(store: store, machineId: model.machine.id) }
      }
      // View → Reconnect (⌘R): only the selected machine's view is mounted, so it is the one that reconnects.
      .onReceive(NotificationCenter.default.publisher(for: RigMainMenu.reconnect)) { _ in model.retry() }
      .onReceive(NotificationCenter.default.publisher(for: RigMainMenu.forgetPassword)) { _ in model.forgetPassword() }
      .onAppear {
        RigMenuTarget.shared.selectedMachineId = model.machine.id
        model.appeared()
      }
      .onDisappear {
        if RigMenuTarget.shared.selectedMachineId == model.machine.id { RigMenuTarget.shared.selectedMachineId = nil }
        model.disappeared()
      }
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

  /// A VNC machine's password, asked in place of the video. Remembered in the
  /// login Keychain by default; kept only once the server has accepted it.
  private struct RigVNCPasswordForm: View {
    let machine: RigMachine
    let prompt: PasswordPrompt
    let submit: (String, Bool) -> Void
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
      VStack(spacing: 4) {
        VStack(spacing: 8) {
          Image(systemName: "lock.display").font(.largeTitle).foregroundStyle(.secondary)
          Text("Enter the VNC password for \(machine.name)").font(.headline)
        }
        Form {
          if let reason = prompt.reason {
            Section {
              Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
          }
          Section {
            SecureField("Password", text: $password, prompt: Text("Required"))
              .focused($focused).onSubmit(connect)
            Toggle("Remember in Keychain", isOn: $remember)
          }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 400)
        HStack {
          Spacer()
          Button("Connect", action: connect).keyboardShortcut(.defaultAction).disabled(password.isEmpty)
        }
        .frame(width: 400 - 40)
      }
      .padding(24)
      .onAppear { focused = true }
    }

    private func connect() {
      guard !password.isEmpty else { return }
      submit(password, remember)
    }
  }

  /// The endpoint's video surface on the native window background, as the product's system theme shows it.
  private struct RigEndpointView: NSViewRepresentable {
    let endpoint: ScreenSharingViewerEndpoint
    func makeNSView(context: Context) -> NSView { endpoint.view }
    func updateNSView(_ nsView: NSView, context: Context) { endpoint.letterbox(.windowBackgroundColor) }
  }
#endif
