import CodevisorCore
import SwiftUI

/// Keep the selection and entry action together so the first presentation
/// cannot capture the previous action from a separate SwiftUI state property.
public struct HarnessAccountsPresentation<Selection>: Identifiable {
  public let id = UUID()
  public let selection: Selection
  public let startsSignIn: Bool

  public init(_ selection: Selection, startsSignIn: Bool = false) {
    self.selection = selection
    self.startsSignIn = startsSignIn
  }
}

public struct HarnessMachineSignIn: Identifiable {
  public let id = UUID()
  public var profileId: String?
  public var providerId: String?
  public init(profileId: String? = nil, providerId: String? = nil) {
    self.profileId = profileId
    self.providerId = providerId
  }
}

extension EnvironmentValues {
  @Entry public var sharedHarnessAccounts = false
  @Entry public var harnessAccountsDismiss: (@MainActor () -> Void)?
  @Entry public var harnessMachineSignIn: (@MainActor (HarnessMachineSignIn) -> Void)?
}

/// The editor is shared by both scopes. Only machine-bound auth needs a chooser.
public struct HarnessAccountsSheet<Editor: View>: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let harnessId: String
  let harnessName: String
  let startsSignIn: Bool
  let editor: (String?, ServerHarness, HarnessMachineSignIn?) -> Editor
  @State private var machineSignIn: HarnessMachineSignIn?
  @State private var sharedHost: (id: String, harness: ServerHarness)?
  @State private var sharedHostError = false
  @State private var isWorking = false

  private var sharesOAuth: Bool { ["claude-code", "codex", "pi", "opencode"].contains(harnessId) }

  public init(
    harnessId: String, harnessName: String, startsSignIn: Bool = false,
    @ViewBuilder editor: @escaping (String?, ServerHarness, HarnessMachineSignIn?) -> Editor
  ) {
    self.harnessId = harnessId
    self.harnessName = harnessName
    self.startsSignIn = startsSignIn
    self.editor = editor
  }

  public var body: some View {
    NavigationStack {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("\(harnessName) Accounts")
        #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            if sharesOAuth && sharedHost == nil || !sharesOAuth && !["pi", "opencode"].contains(harnessId) {
              HarnessAccountsCloseToolbar()
            }
          }
        #endif
    }
    .environment(\.harnessAccountsDismiss, { dismiss() })
    .onPreferenceChange(HarnessAccountsWorkingPreference.self) { isWorking = $0 }
    .interactiveDismissDisabled(isWorking)
    #if os(macOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SheetFooter {
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
          .disabled(isWorking)
        }
      }
      .frame(
        width: harnessId == "opencode" ? 760 : 560,
        height: harnessId == "opencode" ? 540 : (["claude-code", "codex"].contains(harnessId) ? 380 : 480))
    #endif
    .task { if sharesOAuth { await loadSharedHost() } }
    .sheet(item: $machineSignIn) { request in
      NavigationStack {
        machinePicker(request)
          .navigationTitle(harnessName)
          #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              HarnessAccountsCloseToolbar()
            }
          #endif
      }
      .environment(\.harnessAccountsDismiss, { machineSignIn = nil })
      #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter {
            Button("Done") { machineSignIn = nil }.keyboardShortcut(.defaultAction)
          }
        }
        .frame(width: harnessId == "opencode" ? 760 : 560, height: 480)
      #endif
    }
  }

  @ViewBuilder private var content: some View {
    if sharesOAuth {
      if let sharedHost {
        editor(sharedHost.id, sharedHost.harness, initialSignInRequest)
          .environment(\.sharedHarnessAccounts, true)
          .environment(\.harnessMachineSignIn, nil)
      } else if sharedHostError {
        ContentUnavailableView {
          Label("Connect a Machine", systemImage: "network")
        } description: {
          Text("An online machine with \(harnessName) is needed to manage accounts.")
        } actions: {
          Button("Retry") { Task { await loadSharedHost() } }
        }
      } else {
        HarnessAccountsLoadingView()
      }
    } else if let source = HarnessSharedCredentials(rawValue: harnessId) {
      if source == .devin {
        if (try? source.credentials(from: source.content(in: environment.configSync)).isEmpty) == true {
          HarnessSignInInvitation(harnessId: harnessId, harnessName: harnessName) {
            HarnessCredentialImportButton(source: source)
          }
        } else {
          Form { HarnessSharedAccountsSection(source: source) }.formStyle(.grouped)
        }
      } else if let harness = try? HarnessAccountsStore(environment: environment, machineId: "", isShared: true)
        .sharedHarness(id: harnessId, name: harnessName)
      {
        editor(nil, harness, initialSignInRequest)
          .environment(\.sharedHarnessAccounts, true)
          .environment(\.harnessMachineSignIn, { machineSignIn = $0 })
      }
    } else {
      machinePicker(initialSignInRequest)
    }
  }

  private var initialSignInRequest: HarnessMachineSignIn? {
    startsSignIn ? HarnessMachineSignIn(profileId: harnessId == "opencode" ? "default" : nil) : nil
  }

  private func loadSharedHost() async {
    sharedHostError = false
    for machine in environment.machines.allMachines {
      guard environment.machines.statusByMachineId[machine.id]?.isReachable != false else { continue }
      if let harness = try? await environment.machines.client(for: machine.id).listHarnesses().first(where: {
        $0.id == harnessId
      }), harness.isReady {
        sharedHost = (machine.id, harness)
        return
      }
    }
    sharedHostError = true
  }

  private func machinePicker(_ request: HarnessMachineSignIn?) -> some View {
    HarnessAccountMachinePicker(harnessId: harnessId) { machine, harness in
      editor(machine.id, harness, request)
        .environment(\.sharedHarnessAccounts, false)
        .environment(\.harnessMachineSignIn, nil)
        .navigationTitle(machine.name)
    }
  }
}

public struct HarnessAccountMachinePicker<Editor: View>: View {
  @Environment(AppEnvironment.self) private var environment
  let harnessId: String
  let editor: (CodevisorMachine, ServerHarness) -> Editor
  @State private var harnesses: [String: ServerHarness] = [:]
  @State private var failed: Set<String> = []

  public init(harnessId: String, @ViewBuilder editor: @escaping (CodevisorMachine, ServerHarness) -> Editor) {
    self.harnessId = harnessId
    self.editor = editor
  }

  public var body: some View {
    Form {
      Section("Machines") {
        ForEach(environment.machines.allMachines) { machine in
          Group {
            if reachable(machine), let harness = harnesses[machine.id], harness.isReady {
              NavigationLink {
                editor(machine, harness)
              } label: {
                label(machine)
              }
            } else {
              HStack {
                label(machine)
                if failed.contains(machine.id), reachable(machine) {
                  Button("Retry") { Task { await load(machine) } }.buttonStyle(.borderless)
                }
              }
            }
          }
          .task(id: "\(environment.harnessCatalogRevision(for: machine.id)):\(reachable(machine))") {
            await load(machine)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private func label(_ machine: CodevisorMachine) -> some View {
    HStack {
      Label(machine.name, systemImage: machine.id == CodevisorMachine.local.id ? "desktopcomputer" : "server.rack")
      Spacer()
      Text(status(machine)).foregroundStyle(.secondary)
    }
  }

  private func reachable(_ machine: CodevisorMachine) -> Bool {
    environment.machines.statusByMachineId[machine.id]?.isReachable != false
  }

  private func status(_ machine: CodevisorMachine) -> String {
    guard reachable(machine) else { return "Offline" }
    if failed.contains(machine.id) { return "Unavailable" }
    guard let harness = harnesses[machine.id] else { return "Checking…" }
    guard harness.isReady else { return "Not installed" }
    return harness.auth?.isSatisfied == true ? "Signed in" : "Sign in required"
  }

  private func load(_ machine: CodevisorMachine) async {
    guard reachable(machine) else { return }
    do {
      harnesses[machine.id] = try await environment.machines.client(for: machine.id).listHarnesses()
        .first { $0.id == harnessId }
      failed.remove(machine.id)
    } catch { failed.insert(machine.id) }
  }
}

#if os(iOS)
  /// Each page uses the sheet owner's action, so Close dismisses the sheet even after navigation.
  public struct HarnessAccountsCloseToolbar: ToolbarContent {
    @Environment(\.harnessAccountsDismiss) private var close

    public init() {}

    public var body: some ToolbarContent {
      if let close {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark", action: close)
            .labelStyle(.iconOnly)
        }
      }
    }
  }
#endif
