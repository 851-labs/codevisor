import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct ProjectSetupSheet: View {
  let setup: ProjectMachineSetup
  @Environment(\.openURL) private var openURL
  @State private var copiedCode = false
  @State private var shownPlan: ProjectMachineSetup.Plan?

  var body: some View {
    let screen = setup.screen(showing: shownPlan)
    VStack(spacing: 20) {
      VStack(spacing: 4) {
        SheetSymbolImage(screen.symbol)
          .font(.system(size: 30, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
          .padding(.bottom, 6)
          .accessibilityHidden(true)
        Text(screen.title)
          .font(.title3.weight(.semibold))
          .multilineTextAlignment(.center)
        Text(screen.message)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      if hasCard(caution: screen.caution) {
        VStack(spacing: 12) {
          PermissionCard { card(caution: screen.caution) }
          if let codeActivity {
            SheetActivityLabel(codeActivity)
          }
        }
      }

      HStack {
        SheetCancelButton { setup.cancel() }
        Spacer()
        if let activity {
          SheetActivityLabel(activity)
        }
        if setup.offersSignIn {
          Button("Sign In") { setup.signIn() }
            .buttonStyle(.bordered)
        }
        if let primary {
          SheetPrimaryButton(primary.title, isEnabled: primary.isEnabled, action: primary.perform)
        }
      }
      .controlSize(.large)
    }
    .padding(24)
    .frame(width: 460)
    .animation(.snappy(duration: 0.2), value: setup.phase)
    .onChange(of: setup.plan, initial: true) { _, plan in
      if let plan { shownPlan = plan }
    }
  }

  private func hasCard(caution: String?) -> Bool {
    switch setup.phase {
    case .idle, .unavailable, .finished: return false
    case let .running(plan): return plan.needsRemote
    case let .failed(plan, _): return plan.needsRemote || caution != nil
    case let .signingIn(_, model): return showsCodeOrFailure(model)
    default: return true
    }
  }

  private var activity: String? {
    guard codeActivity == nil else { return nil }
    return setup.activity
  }

  private var codeActivity: String? {
    guard case let .signingIn(_, model) = setup.phase, case .waiting = model.step else { return nil }
    return model.activity
  }

  private func showsCodeOrFailure(_ model: GitSignInModel) -> Bool {
    switch model.step {
    case .waiting, .failed: return true
    default: return false
    }
  }

  @ViewBuilder
  private func card(caution message: String?) -> some View {
    switch setup.phase {
    case let .signingIn(_, model):
      signInRows(model)
    default:
      if let plan = shownPlan {
        if plan.needsRemote {
          remoteSteps(plan)
        } else if isEditable {
          envRow(plan)
        }
        if let message {
          if plan.needsRemote { Divider() }
          caution(message)
        }
      }
    }
  }

  @ViewBuilder
  private func remoteSteps(_ plan: ProjectMachineSetup.Plan) -> some View {
    PermissionRow(symbol: "1.circle", title: "Create an empty repo") {
      if let url = plan.remoteProvider.newRepositoryURL(named: plan.projectName) {
        Button {
          openURL(url)
        } label: {
          HStack(spacing: 4) {
            Text(plan.createRepoTitle)
            Image(systemName: "arrow.up.right")
              .imageScale(.small)
          }
        }
        .buttonStyle(.bordered)
        .fixedSize()
      }
    }
    Divider()
    PermissionRow(symbol: "2.circle", title: "Paste its link") {
      EmptyView()
    }
    TextField(
      "Repository URL",
      text: Binding(get: { setup.plan?.repoUrl ?? "" }, set: { setup.setRepoUrl($0) }),
      prompt: Text(verbatim: plan.repoPlaceholder)
    )
    .textFieldStyle(.roundedBorder)
    .font(.body.monospaced())
    .disabled(setup.isPushing)
    .onSubmit { setup.confirm() }
    .padding(.leading, 46)
    .padding(.bottom, 12)
  }

  private func envRow(_ plan: ProjectMachineSetup.Plan) -> some View {
    PermissionRow(symbol: "key", title: "Copy env files") {
      Toggle(
        "Copy env files",
        isOn: Binding(get: { plan.copiesEnvFiles }, set: { setup.setCopiesEnvFiles($0) })
      )
      .toggleStyle(.switch)
      .labelsHidden()
    }
  }

  private func caution(_ text: String) -> some View {
    Label {
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private func signInRows(_ model: GitSignInModel) -> some View {
    switch model.step {
    case let .waiting(_, flow):
      let code = flow.userCode ?? ""
      VStack(spacing: 8) {
        Text(code)
          .font(.system(.title2, design: .monospaced, weight: .semibold))
          .textSelection(.enabled)
        Button {
          copy(code)
        } label: {
          Label(copiedCode ? "Copied" : "Copy Code", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
    case let .failed(_, message):
      caution(firstLine(message))
    case .idle, .starting, .confirmingSetup, .installing, .signedIn:
      EmptyView()
    }
  }

  private var isEditable: Bool {
    switch setup.phase {
    case .preparing, .confirming: return true
    default: return false
    }
  }

  private struct Primary {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
  }

  private var primary: Primary? {
    switch setup.phase {
    case let .confirming(plan):
      return Primary(title: plan.needsRemote ? plan.pushTitle : plan.cloneTitle, isEnabled: plan.isReady) {
        setup.confirm()
      }
    case let .failed(plan, _):
      return Primary(title: ProjectMachineSetup.retryTitle, isEnabled: plan.isReady) { setup.retry() }
    case let .preparing(plan):
      return Primary(title: plan.needsRemote ? plan.pushTitle : plan.cloneTitle, isEnabled: false) {}
    case .running, .finished:
      return nil
    case let .signingIn(_, model):
      switch model.step {
      case let .waiting(provider, flow):
        let url = flow.verificationUrl.flatMap(URL.init(string:))
        return Primary(title: "Open \(provider.displayName)", isEnabled: url != nil) {
          if let url { openURL(url) }
        }
      case .confirmingSetup:
        return Primary(title: ProjectMachineSetup.setUpTitle, isEnabled: true) { model.setUp() }
      case .failed:
        return Primary(title: ProjectMachineSetup.retryTitle, isEnabled: true) { model.retry() }
      default:
        return nil
      }
    case .idle, .unavailable:
      return nil
    }
  }

  private func firstLine(_ text: String) -> String {
    text.components(separatedBy: "\n").first ?? text
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    copiedCode = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copiedCode = false
    }
  }
}
