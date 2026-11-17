#if os(macOS)
  import CodevisorCore
  import SwiftUI

  public struct PluginConnectSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var model: PluginConnectModel
    private let client: any CodevisorServerClienting

    public init(entry: ServerPluginCatalogEntry, client: any CodevisorServerClienting, host: PluginConnectHost) {
      _model = State(initialValue: PluginConnectModel(entry: entry, client: client, host: host))
      self.client = client
    }

    private var entry: ServerPluginCatalogEntry { model.entry }

    private var restriction: String? {
      environment.pluginAccess.restriction(for: PluginModerationSubject(catalogEntry: entry))
    }

    private var canContinue: Bool {
      model.canContinue && restriction == nil && model.primaryTitle != nil
    }

    public var body: some View {
      VStack(spacing: 20) {
        PluginConnectHeader(entry: entry, client: client)
        if hasDetails { details }
        PluginConnectProblems(restriction: restriction, errorMessage: model.errorMessage)
        VStack(spacing: 10) {
          PluginConnectActions(model: model, canContinue: canContinue, run: run) { dismiss() }
          Text("By installing, you agree to the [Plugin terms](https://codevisor.dev/terms#plugins).")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
      }
      .padding(.vertical, 28)
      .frame(width: 460)
      .disabled(model.isWorking)
      .interactiveDismissDisabled(model.isWorking)
      .task { await model.load() }
      .task { try? await environment.pluginAccess.refresh() }
    }

    private var hasDetails: Bool {
      let capabilities = entry.capabilities
      let listed = [
        capabilities.tools.count, capabilities.skills.count, capabilities.events.count, capabilities.panes.count,
      ]
      return listed.contains { $0 > 0 } || !model.draft.fields.isEmpty
    }

    private var details: some View {
      Form {
        PluginCapabilitySections(capabilities: entry.capabilities)
        if !model.draft.fields.isEmpty {
          Section("Configuration") {
            ConfigFieldForm(draft: $model.draft)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .contentMargins(.vertical, 0, for: .scrollContent)
      .padding(.horizontal, 8)
      .frame(maxHeight: 360)
      .fixedSize(horizontal: false, vertical: true)
    }

    private func run(_ choice: PluginConnectModel.Choice) {
      Task {
        if await model.run(choice) { dismiss() }
      }
    }
  }

  private struct PluginConnectHeader: View {
    let entry: ServerPluginCatalogEntry
    let client: any CodevisorServerClienting

    var body: some View {
      VStack(spacing: 12) {
        HStack(spacing: 12) {
          CodevisorAppIconView(size: 74)
          HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
              Circle().fill(.tertiary).frame(width: 4, height: 4)
            }
          }
          PluginCatalogIcon(entry: entry, client: client, side: 60)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(7)
        }
        .accessibilityHidden(true)
        VStack(spacing: 4) {
          Text(entry.name).font(.title.weight(.semibold))
          if !entry.description.isEmpty {
            Text(entry.description)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(.horizontal, 28)
    }
  }

  private struct PluginConnectActions: View {
    let model: PluginConnectModel
    let canContinue: Bool
    let run: (PluginConnectModel.Choice) -> Void
    let cancel: () -> Void

    var body: some View {
      VStack(spacing: 10) {
        Button {
          run(.finishSetup)
        } label: {
          primaryLabel.frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!canContinue)
        VStack(spacing: 10) {
          if let skipTitle = model.skipTitle {
            Button(skipTitle) { run(.skipSignIn) }.disabled(!canContinue)
          }
          Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.link)
      }
    }

    @ViewBuilder
    private var primaryLabel: some View {
      if model.isWorking {
        ProgressView().controlSize(.small)
      } else {
        Text(model.primaryTitle ?? "Checking sign-in…")
      }
    }
  }

  private struct PluginConnectProblems: View {
    let restriction: String?
    let errorMessage: String?

    var body: some View {
      if restriction != nil || errorMessage != nil {
        VStack(spacing: 8) {
          if let restriction {
            Text(restriction)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.callout)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.horizontal, 28)
      }
    }
  }
#endif
