import CodevisorCore
import SwiftUI

public struct PluginConnectSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var model: PluginConnectModel
  private let client: any CodevisorServerClienting

  public init(
    entry: ServerPluginCatalogEntry,
    installed: ServerMcpServer? = nil,
    client: any CodevisorServerClienting,
    host: PluginConnectHost
  ) {
    _model = State(
      initialValue: PluginConnectModel(entry: entry, installed: installed, client: client, host: host))
    self.client = client
  }

  private var entry: ServerPluginCatalogEntry { model.entry }

  private var subject: PluginModerationSubject { PluginModerationSubject(catalogEntry: entry) }

  private var restriction: String? {
    environment.pluginAccess.restriction(for: subject)
  }

  private var lists: PluginCapabilityLists { PluginCapabilityLists(capabilities: entry.capabilities) }

  private var canContinue: Bool {
    model.canContinue && restriction == nil && model.primaryTitle != nil
  }

  public var body: some View {
    NavigationStack { content.modifier(ClearsInitialFocus()) }
      #if os(macOS)
        .frame(width: 460)
      #endif
      .disabled(model.isWorking)
      .interactiveDismissDisabled(model.isWorking)
      .task { await model.load() }
      .task { try? await environment.pluginAccess.refresh() }
  }

  #if os(macOS)
    private var content: some View {
      VStack(spacing: 20) {
        PluginConnectHeader(entry: entry, client: client)
        if hasDetails { details }
        problems
        footer
      }
      .padding(.vertical, 28)
      .overlay(alignment: .topTrailing) {
        PluginConnectCloseButton { dismiss() }.padding(12)
      }
    }

    private var hasDetails: Bool {
      !lists.summaries.isEmpty || !model.draft.fields.isEmpty
    }

    private var details: some View {
      Form {
        PluginCapabilityLinks(lists: lists)
        configuration
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .contentMargins(.vertical, 0, for: .scrollContent)
      .padding(.horizontal, 8)
      .frame(maxHeight: 360)
      .fixedSize(horizontal: false, vertical: true)
    }
  #else
    private var content: some View {
      Form {
        Section {
          PluginConnectHeader(entry: entry, client: client)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        Section {
          PluginAgeRatingRow(subject: subject)
          ForEach(lists.summaries) { summary in
            NavigationLink {
              PluginCapabilityListPage(summary.page, lists: lists)
            } label: {
              PluginListRowLabel(summary)
            }
          }
        }
        configuration
        if !subject.isFirstParty { PluginModerationSection(subject: subject) }
      }
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 12) {
          problems
          footer
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
      }
    }
  #endif

  @ViewBuilder
  private var configuration: some View {
    if !model.draft.fields.isEmpty {
      Section("Configuration") {
        ConfigFieldForm(draft: $model.draft)
      }
    }
  }

  private var problems: some View {
    PluginConnectProblems(restriction: restriction, signInNote: model.signInNote, errorMessage: model.errorMessage)
      .padding(.horizontal, 28)
  }

  private var footer: some View {
    VStack(spacing: 10) {
      PluginConnectActions(model: model, canContinue: canContinue, run: run)
      if !model.isInstalled { PluginConnectTerms() }
    }
    .padding(.horizontal, 28)
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
      if let skipTitle = model.skipTitle {
        Button {
          run(.skipSignIn)
        } label: {
          Text(skipTitle).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canContinue)
      }
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

#if os(macOS)
  private struct PluginConnectCloseButton: View {
    let close: () -> Void

    var body: some View {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .background(.quaternary, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityLabel("Close")
      .help("Close")
    }
  }
#endif

private struct PluginConnectProblems: View {
  let restriction: String?
  let signInNote: String?
  let errorMessage: String?

  private var notes: [String] { [restriction, signInNote].compactMap(\.self) }

  var body: some View {
    if !notes.isEmpty || errorMessage != nil {
      VStack(spacing: 8) {
        ForEach(notes, id: \.self) { note in
          Text(note)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

private struct PluginConnectTerms: View {
  var body: some View {
    Text("By installing, you agree to the [Plugin terms](https://codevisor.dev/terms#plugins).")
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.top, 4)
  }
}
