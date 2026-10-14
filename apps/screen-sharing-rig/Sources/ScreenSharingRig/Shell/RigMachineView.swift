#if os(macOS)
  import CodevisorClient
  import CodevisorCoreMac
  import ComposableArchitecture
  import Foundation
  import os
  import ScreenSharing
  import ScreenSharingRigKit
  import Security
  import SwiftUI

  @MainActor
  @Observable
  final class RigMachineModel {
    let machine: RigMachine
    private(set) var store: StoreOf<ScreenSharingViewer>?
    private(set) var preparing: String?
    private(set) var failure: String?
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

    func retry() {
      store?.send(.paneClosed)
      store = nil
      prepare()
    }

    func signIn(username: String?, password: String, remember: Bool) {
      store?.send(.paneClosed)
      store = nil
      prepare(typed: RigVNCSignIn.Typed(username: username, password: password, remember: remember))
    }

    func machineSettings() -> ScreenSharingMachineSettings {
      var settings = ScreenSharingMachineSettings(
        name: machine.name, connection: "",
        dynamicResolution: store?.dynamicResolution
          ?? RigMachineSettings.dynamicResolution(machine.id),
        displays: store?.displays.map { .init(id: $0.id, name: $0.name) } ?? [],
        preferredDisplayId: store?.selectedDisplayId, lastConnected: RigMachineSettings.lastConnected(machine.id),
        sound: store?.endpoint?.audio.map { .init(enabled: $0.enabled, volume: $0.volume) })
      if let endpoint = store?.endpoint,
        !endpoint.supportsDynamicResolution || endpoint.resolutionAvailability.available == false
      {
        settings.dynamicResolutionNote = "This machine can't change its resolution over this connection."
      }
      if case .server = machine.connection, store?.endpoint?.supportsHighDynamicRange != false {
        settings.highDynamicRange = RigMachineSettings.highDynamicRange(machine.id)
        settings.highDynamicRangeNote = store?.endpoint?.highDynamicRangeNote
      }
      switch machine.connection {
      case .server(let url, _):
        settings.connection = "Codevisor server"
        settings.address = url.host().map { host in url.port.map { "\(host):\($0)" } ?? host }
      case .vnc(let host, let port, let password):
        settings.connection = "VNC"
        settings.address = "\(host):\(port)"
        if password == .keychain {
          let saved = RigVNCSignIn.saved(machineId: machine.id, store: RigKeychain.vncPasswords)
          settings.signIn = .init(userName: saved.userName, hasSavedPassword: saved.hasPassword)
        }
      }
      return settings
    }

    func applySettings(_ changes: ScreenSharingMachineSettingsChanges) {
      if let enabled = changes.dynamicResolution {
        RigMachineSettings.setDynamicResolution(enabled, for: machine.id)
        if let store, store.dynamicResolution != enabled { store.send(.dynamicResolutionToggled) }
      }
      if let enabled = changes.highDynamicRange {
        RigMachineSettings.setHighDynamicRange(enabled, for: machine.id)
        store?.endpoint?.highDynamicRange = enabled
      }
      if let sound = changes.sound {
        RigMachineSettings.setSound(sound, for: machine.id)
        store?.endpoint?.audio?.apply(sound)
      }
      if let display = changes.preferredDisplayId { store?.send(.displaySelected(display)) }
      guard changes.userName != nil || changes.password != .keep else { return }
      let password: RigVNCSignIn.PasswordChange =
        switch changes.password {
        case .keep: .keep
        case .forget: .forget
        case .replace(let new): .replace(new)
        }
      do {
        if try RigVNCSignIn.update(
          machineId: machine.id, userName: changes.userName, password: password, store: RigKeychain.vncPasswords)
        {
          retry()
        }
      } catch {
        failure = "The Keychain didn't save the sign-in: \(error.localizedDescription)"
      }
    }

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

    private static func backend(
      _ machine: RigMachine, typed: RigVNCSignIn.Typed?, progress: @MainActor (String) -> Void
    ) async throws -> ScreenSharingViewerBackend {
      switch machine.connection {
      case .vnc(let host, let port, let source):
        if source == .keychain { progress("Signing in to \(host)…") }
        let signedIn = RigSignedInConnection()
        let outcome = try await RigVNCSignIn.signIn(
          machineId: machine.id, password: source, typed: typed, store: RigKeychain.vncPasswords
        ) { credential in
          signedIn.keep(
            try await VNCConnection.open(
              host: host, port: port, password: credential.password, username: credential.username))
        }
        let credential: RigVNCCredential?
        switch outcome {
        case .signedIn(let accepted): credential = accepted
        case .needsPassword(let reason):
          signedIn.close()
          let offered = (try? await VNCConnection.securityTypes(host: host, port: port)) ?? []
          throw PasswordPrompt(
            reason: reason, accountSignIn: offered.contains(RFBSecurityType.appleRemoteDesktop.rawValue))
        }
        return .vnc(
          displayId: RigMachine.vncDisplayId(port: port),
          open: {
            if let kept = signedIn.take() { return kept }
            return try await VNCConnection.open(
              host: host, port: port, password: credential?.password, username: credential?.username)
          })
      case .server(let url, let sshTarget):
        let connected: (client: CodevisorServerClient, token: String?, provider: String?)
        do {
          connected = try await Self.client(
            machine.id, url: url, sshTarget: sshTarget, fresh: false, progress: progress)
        } catch CodevisorServerClientError.httpStatus(401, _) {
          connected = try await Self.client(machine.id, url: url, sshTarget: sshTarget, fresh: true, progress: progress)
        }
        guard connected.provider != "vnc", let token = connected.token else {
          return .native(client: connected.client, workspaceId: UUID(), paneId: UUID())
        }
        progress("Preparing the rig's Screen Sharing pane…")
        try await RigServerPane.ensure(baseURL: url, token: token)
        return .native(client: connected.client, workspaceId: RigServerPane.workspaceId, paneId: RigServerPane.paneId)
      }
    }

    private static func client(
      _ id: String, url: URL, sshTarget: String, fresh: Bool, progress: @MainActor (String) -> Void
    ) async throws -> (client: CodevisorServerClient, token: String?, provider: String?) {
      var token = fresh ? nil : RigKeychain.machineTokens.read(id)
      if token == nil {
        progress("Asking \(sshTarget) for its token…")
        let fetched = try await RigMachineTokenStore.fetch(sshTarget: sshTarget)
        try? RigKeychain.machineTokens.save(fetched, for: id)
        token = fetched
      }
      progress("Connecting to \(url.host() ?? id)…")
      let client = CodevisorServerClient(config: CodevisorServerConfig(baseURL: url, bearerToken: token))
      let capabilities = ServerScreenSharingRequest(
        operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
      let reply = try await ScreenSharingTransientRetry.run(sleep: { try await Task.sleep(for: $0) }) {
        try await client.screenSharing(capabilities)
      }
      return (client, token, reply.provider)
    }
  }

  final class RigSignedInConnection: Sendable {
    private let connection = OSAllocatedUnfairLock<(client: RFBClient, outcome: RFBHandshake.Outcome)?>(
      uncheckedState: nil)

    func keep(_ opened: (client: RFBClient, outcome: RFBHandshake.Outcome)) {
      connection.withLockUnchecked { $0 = opened }
    }

    func take() -> (client: RFBClient, outcome: RFBHandshake.Outcome)? {
      connection.withLockUnchecked { kept in
        defer { kept = nil }
        return kept
      }
    }

    func close() { take()?.client.close() }

    deinit { close() }
  }

  struct PasswordPrompt: Error, Equatable {
    let reason: String?
    var accountSignIn = false
  }

  struct RigMachineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

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
          RigVNCPasswordForm(machine: model.machine, prompt: prompt) {
            model.signIn(username: $0, password: $1, remember: $2)
          }
        } else if let message = model.failure {
          failure(message) { model.retry() }
        } else {
          progress(model.preparing ?? "Connecting to \(model.machine.name)…")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: model.store?.endpoint?.id) { _, _ in
        model.store?.endpoint?.audio?.apply(RigMachineSettings.sound(model.machine.id))
        model.store?.endpoint?.highDynamicRange = RigMachineSettings.highDynamicRange(model.machine.id)
        model.store?.endpoint?.clipboard?.sharing = true
      }
      .onChange(of: model.store?.phase) { _, phase in
        if phase == .viewing { RigMachineSettings.setLastConnected(Date(), for: model.machine.id) }
      }
      .navigationTitle(model.machine.name)
      .navigationSubtitle(model.machine.detail)
      .toolbar {
        if let store = model.store {
          RigScreenSharingToolbar(
            store: store, machineId: model.machine.id, settings: { model.machineSettings() },
            applySettings: { model.applySettings($0) })
        }
      }
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

    private func progress(_ message: String, notice: String? = nil) -> some View {
      VStack(spacing: 12) {
        ProgressView().controlSize(.small)
        Text(message)
        if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
      }
      .padding(24)
    }

    private func connection(_ store: StoreOf<ScreenSharingViewer>) -> some View {
      VStack(spacing: 0) {
        if let message = store.lease?.message { banner(message) }
        if let message = store.endpoint?.clipboard?.message { banner(message) }
        if store.phase == .viewing, let notice = store.hostNotice { banner(notice) }
        ZStack {
          if let endpoint = store.endpoint {
            RigEndpointView(endpoint: endpoint)
          }
          if store.phase != .viewing {
            progress(
              store.phase == .reconnecting
                ? "Reconnecting to \(model.machine.name)…" : "Connecting to \(model.machine.name)…",
              notice: store.hostNotice)
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

  private struct RigVNCPasswordForm: View {
    let machine: RigMachine
    let prompt: PasswordPrompt
    let submit: (String?, String, Bool) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    private enum Field { case username, password }
    @FocusState private var focused: Field?

    var body: some View {
      VStack(spacing: 4) {
        VStack(spacing: 8) {
          Image(systemName: "lock.display").font(.largeTitle).foregroundStyle(.secondary)
          Text(prompt.accountSignIn ? "Sign in to \(machine.name)" : "Enter the VNC password for \(machine.name)")
            .font(.headline)
        }
        Form {
          if let reason = prompt.reason {
            Section {
              Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
          }
          Section {
            if prompt.accountSignIn {
              TextField("User name", text: $username, prompt: Text("This Mac's account"))
                .focused($focused, equals: .username).onSubmit(connect)
            }
            SecureField("Password", text: $password, prompt: Text("Required"))
              .focused($focused, equals: .password).onSubmit(connect)
            Toggle("Remember in Keychain", isOn: $remember)
          } footer: {
            if prompt.accountSignIn {
              Text(
                "Signing in as the Mac's user lets it know who you are. Leave the user name empty to use the VNC password."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
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
      .onAppear { focused = prompt.accountSignIn ? .username : .password }
    }

    private func connect() {
      guard !password.isEmpty else { return }
      submit(username.trimmingCharacters(in: .whitespaces), password, remember)
    }
  }

  private struct RigEndpointView: NSViewRepresentable {
    let endpoint: ScreenSharingViewerEndpoint
    func makeNSView(context: Context) -> NSView { endpoint.view }
    func updateNSView(_ nsView: NSView, context: Context) { endpoint.letterbox(.windowBackgroundColor) }
  }
#endif
