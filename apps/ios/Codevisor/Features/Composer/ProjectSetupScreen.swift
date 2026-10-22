import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

struct ProjectSetupScreen: View {
  let setup: ProjectMachineSetup
  @Environment(\.openURL) private var openURL
  @State private var copiedCode = false
  @State private var shownPlan: ProjectMachineSetup.Plan?
  @State private var contentHeight: CGFloat = 420

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          header
          cards
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
      }
      .scrollDismissesKeyboard(.interactively)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
      } action: { _, height in
        contentHeight = height
      }
      .safeAreaInset(edge: .bottom) { actions }
      .background(Color(.systemBackground))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark", role: .cancel) { setup.cancel() }
            .labelStyle(.iconOnly)
        }
      }
    }
    .presentationDetents([.height(contentHeight)])
    .presentationBackground(Color(.systemBackground))
    .interactiveDismissDisabled(setup.isRunning)
    .animation(.snappy(duration: 0.2), value: setup.phase)
    .onChange(of: setup.plan, initial: true) { _, plan in
      if let plan { shownPlan = plan }
    }
  }

  private var header: some View {
    let screen = setup.screen(showing: shownPlan)
    return VStack(spacing: 12) {
      Image(systemName: screen.symbol)
        .font(.system(size: 52))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text(screen.title)
        .font(.title.bold())
        .multilineTextAlignment(.center)
      Text(screen.message)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 8)
  }

  @ViewBuilder
  private var cards: some View {
    switch setup.phase {
    case let .signingIn(_, model):
      signIn(model)
    case .idle, .unavailable:
      EmptyView()
    default:
      if isCloning {
        card {
          ProgressView(value: setup.progress.fraction) {
            Text(setup.progress.label)
          } currentValueLabel: {
            Text(setup.progress.detail ?? " ")
          }
          .monospacedDigit()
          .padding(16)
        }
      } else if let plan = shownPlan {
        if plan.needsRemote {
          remoteSteps(plan)
        } else if isEditable {
          card {
            Toggle(
              isOn: Binding(get: { plan.copiesEnvFiles }, set: { setup.setCopiesEnvFiles($0) })
            ) {
              Label("Copy env files", systemImage: "key")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func remoteSteps(_ plan: ProjectMachineSetup.Plan) -> some View {
    card {
      VStack(spacing: 0) {
        step(1, "Create an empty repo") {
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
          }
        }
        Divider().padding(.leading, 56)
        step(2, "Paste its link") {
          TextField(
            "Repository URL",
            text: Binding(get: { setup.plan?.repoUrl ?? "" }, set: { setup.setRepoUrl($0) }),
            prompt: Text(verbatim: plan.repoPlaceholder)
          )
          .font(.body.monospaced())
          .textFieldStyle(.roundedBorder)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .textContentType(.URL)
          .submitLabel(.go)
          .onSubmit { setup.confirm() }
          .disabled(setup.isPushing)
        }
      }
    }
  }

  private func step<Content: View>(
    _ number: Int, _ title: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: "\(number).circle.fill")
        .font(.title3)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 10) {
        Text(title)
          .font(.headline)
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var actions: some View {
    VStack(spacing: 8) {
      if let message = errorMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 4)
      }
      if let primary {
        Button(primary.title, action: primary.perform)
          .buttonStyle(
            OnboardingFilledButtonStyle(
              background: primary.isEnabled || primary.showsProgress ? .accentColor : Color(.tertiarySystemFill),
              foreground: primary.isEnabled || primary.showsProgress ? .white : .secondary,
              showsProgress: primary.showsProgress
            )
          )
          .disabled(!primary.isEnabled)
      }
      if setup.offersSignIn {
        Button("Sign In") { setup.signIn() }
          .font(.subheadline.weight(.medium))
      }
      if let note = actionNote {
        SheetActivityLabel(note)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .padding(.bottom, 12)
    .background(Color(.systemBackground))
  }

  private var errorMessage: String? {
    switch setup.phase {
    case .failed: setup.screen(showing: shownPlan).caution
    case let .signingIn(_, model):
      if case let .failed(_, message) = model.step {
        message.components(separatedBy: "\n").first ?? message
      } else {
        nil
      }
    case .unavailable: "Try again when that machine is online."
    default: nil
    }
  }

  private var actionNote: String? {
    guard case let .signingIn(_, model) = setup.phase else { return nil }
    switch model.step {
    case .waiting: return "Waiting for sign-in…"
    case let .installing(provider): return "Installing \(provider.cliName)…"
    case .idle, .starting, .signedIn: return "Starting sign-in…"
    case .failed: return nil
    }
  }

  @ViewBuilder
  private func signIn(_ model: GitSignInModel) -> some View {
    if case let .waiting(_, flow) = model.step {
      let code = flow.userCode ?? ""
      card {
        VStack(spacing: 10) {
          Text(code)
            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
            .tracking(2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
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
        .padding(.vertical, 18)
      }
    }
  }

  private var isCloning: Bool {
    switch setup.phase {
    case let .running(plan): !plan.needsRemote
    case .finished: true
    default: false
    }
  }

  private var isEditable: Bool {
    switch setup.phase {
    case .preparing, .confirming: true
    default: false
    }
  }

  private struct Primary {
    let title: String
    let isEnabled: Bool
    var showsProgress = false
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
    case let .running(plan):
      return Primary(
        title: plan.needsRemote ? plan.pushTitle : plan.cloneTitle, isEnabled: false, showsProgress: true
      ) {}
    case .finished:
      return shownPlan.map { Primary(title: $0.cloneTitle, isEnabled: false, showsProgress: true) {} }
    case let .signingIn(_, model):
      switch model.step {
      case let .waiting(provider, flow):
        let url = flow.verificationUrl.flatMap(URL.init(string:))
        return Primary(title: "Open \(provider.displayName)", isEnabled: url != nil) {
          if let url { openURL(url) }
        }
      case let .failed(provider, _):
        return Primary(title: ProjectMachineSetup.retryTitle, isEnabled: true) { model.signIn(with: provider) }
      default:
        return nil
      }
    case .idle, .unavailable:
      return nil
    }
  }

  private func copy(_ value: String) {
    UIPasteboard.general.string = value
    copiedCode = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copiedCode = false
    }
  }
}
