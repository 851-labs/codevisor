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

    public var body: some View {
      SetupSheet(
        symbol: nil,
        title: entry.name,
        subtitle: entry.description.isEmpty ? nil : entry.description,
        primaryTitle: model.primaryTitle,
        cancelTitle: "Cancel",
        canContinue: model.canContinue && restriction == nil,
        status: status,
        onCancel: { dismiss() },
        secondaryTitle: model.skipTitle,
        onSecondary: { run(.skipSignIn) },
        onContinue: { run(.finishSetup) },
        stepsInCard: false,
        icon: AnyView(PluginConnectHeader(entry: entry, client: client))
      ) {
        VStack(spacing: 14) {
          PluginConnectCapabilities(capabilities: entry.capabilities)
          if !model.draft.fields.isEmpty {
            PermissionCard {
              Form { ConfigFieldForm(draft: $model.draft) }
                .formStyle(.columns)
                .padding(.vertical, 8)
            }
          }
          PluginConnectNotices(name: entry.name, restriction: restriction, errorMessage: model.errorMessage)
        }
      }
      .disabled(model.isWorking)
      .interactiveDismissDisabled(model.isWorking)
      .task { await model.load() }
      .task { try? await environment.pluginAccess.refresh() }
    }

    private var status: String? {
      if model.isWorking { return "Installing…" }
      return model.setup == .checking ? "Checking sign-in…" : nil
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
      HStack(spacing: 10) {
        CodevisorAppIconView(size: 64)
        HStack(spacing: 4) {
          ForEach(0..<3, id: \.self) { _ in
            Circle().fill(.tertiary).frame(width: 4, height: 4)
          }
        }
        PluginCatalogIcon(entry: entry, client: client, side: 52)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .padding(6)
      }
      .accessibilityHidden(true)
    }
  }

  private struct PluginConnectNotices: View {
    let name: String
    let restriction: String?
    let errorMessage: String?

    var body: some View {
      VStack(spacing: 8) {
        PluginConsentNotice(name: name)
          .multilineTextAlignment(.center)
        if let restriction {
          Text(restriction)
            .font(.footnote)
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
      .frame(maxWidth: .infinity)
    }
  }
#endif
