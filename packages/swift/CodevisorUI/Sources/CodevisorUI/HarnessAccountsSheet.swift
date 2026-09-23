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
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  let harnessId: String
  let harnessName: String
  let startsSignIn: Bool
  /// The machine to host the sign-in when the caller has one in mind (the
  /// chat that hit the error); any online machine with the harness works.
  let preferredMachineId: String?
  let editor: (String?, ServerHarness, HarnessMachineSignIn?) -> Editor
  @State private var machineSignIn: HarnessMachineSignIn?
  @State private var sharedHost: HarnessFleet.SharedHost?
  @State private var sharedHostError = false
  @State private var operation: String?
  @State private var pickerOperation: String?

  private var descriptor: HarnessDescriptor { HarnessRegistry.descriptor(for: harnessId) }
  private var sharesOAuth: Bool { descriptor.fleetSignInNeedsMachine }
  private var isWorking: Bool { operation != nil }
  #if os(macOS)
    private var metrics: SheetMetrics { descriptor.usesProviderBrowser ? .browser : .list }
  #endif

  public init(
    harnessId: String, harnessName: String, startsSignIn: Bool = false, preferredMachineId: String? = nil,
    @ViewBuilder editor: @escaping (String?, ServerHarness, HarnessMachineSignIn?) -> Editor
  ) {
    self.harnessId = harnessId
    self.harnessName = harnessName
    self.startsSignIn = startsSignIn
    self.preferredMachineId = preferredMachineId
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
            // Editors that host their own navigation bring their own Close.
            if sharesOAuth && sharedHost == nil || !sharesOAuth {
              HarnessAccountsCloseToolbar()
            }
          }
        #endif
    }
    .environment(\.harnessAccountsDismiss, { dismiss() })
    .onPreferenceChange(HarnessAccountsWorkingPreference.self) { operation = $0 }
    .interactiveDismissDisabled(isWorking)
    #if os(macOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SheetFooter(status: operation) {
          Button("Done") { dismiss() }
          .settingsActionTint(theme)
          .keyboardShortcut(.defaultAction)
          .disabled(isWorking)
        }
      }
      .sheetSize(metrics)
      .themedSurface(.sheet)
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
      // A nested sheet is its own presentation, so the outer sheet's
      // preference reader never sees this editor's work. It reads its own.
      .onPreferenceChange(HarnessAccountsWorkingPreference.self) { pickerOperation = $0 }
      .interactiveDismissDisabled(pickerOperation != nil)
      #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
          SheetFooter(status: pickerOperation) {
            Button("Done") { machineSignIn = nil }
            .keyboardShortcut(.defaultAction)
            .disabled(pickerOperation != nil)
          }
        }
        .sheetSize(metrics)
        .themedSurface(.sheet)
      #endif
    }
  }

  @ViewBuilder private var content: some View {
    if sharesOAuth {
      if let sharedHost {
        editor(sharedHost.machineId, sharedHost.harness, initialSignInRequest)
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
        SheetLoadingView("Connecting to a machine…")
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
    }
    // Machine-bound accounts never reach this sheet: the harness list
    // opens them on the machine directly.
  }

  private var initialSignInRequest: HarnessMachineSignIn? {
    startsSignIn ? HarnessMachineSignIn(profileId: harnessId == "opencode" ? "default" : nil) : nil
  }

  private func loadSharedHost() async {
    sharedHostError = false
    let host = await HarnessFleet.findSharedHost(
      harnessId: harnessId, preferred: preferredMachineId, environment: environment)
    guard !Task.isCancelled else { return }
    sharedHost = host
    sharedHostError = host == nil
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

struct HarnessAccountMachinePicker<Editor: View>: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let harnessId: String
  let editor: (CodevisorMachine, ServerHarness) -> Editor
  @State private var harnesses: [String: ServerHarness] = [:]
  @State private var failed: Set<String> = []

  init(harnessId: String, @ViewBuilder editor: @escaping (CodevisorMachine, ServerHarness) -> Editor) {
    self.harnessId = harnessId
    self.editor = editor
  }

  var body: some View {
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
      Text(status(machine)).foregroundStyle(theme.textSecondary)
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
          // `role: .close` is the iOS 26 dismissal idiom. Dismissal is the
          // one action universally understood as a glyph, so it stays
          // icon-only; confirm actions keep their verb as text.
          Button("Close", systemImage: "xmark", role: .close, action: close)
            .labelStyle(.iconOnly)
        }
      }
    }
  }
#endif
