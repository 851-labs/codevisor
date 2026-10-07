import CodevisorCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Adds a provider or replaces its credential, for every harness that signs
/// in per provider: choose the provider and how to sign in, then follow its
/// page, code or questions until it's done.
struct HarnessProviderSignInSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.theme) private var theme

  @State private var draft: HarnessProviderSignInDraft
  private let configuredIds: Set<String>
  private let onComplete: () async -> Void
  #if os(macOS)
    @State private var search = ""
  #endif

  init(accounts: HarnessProviderAccounts, providerId: String?, onComplete: @escaping () async -> Void) {
    _draft = State(
      initialValue: HarnessProviderSignInDraft(
        providers: accounts.available, providerId: providerId, backend: accounts.backend))
    configuredIds = Set(accounts.configured.map(\.id))
    self.onComplete = onComplete
  }

  private var title: String {
    if draft.signIn != nil { return draft.provider?.name ?? "Sign In" }
    return draft.isReplacing ? "Replace Credential" : "Add Provider"
  }

  var body: some View {
    NavigationStack {
      #if os(macOS)
        // Picking a provider needs no title; the list gets the room. A
        // sign-in in progress is titled with its provider.
        if draft.signIn != nil {
          content.navigationTitle(title)
        } else {
          content
        }
      #else
        content.navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                .labelStyle(.iconOnly)
                .disabled(draft.isWorking)
            }
            if let actionTitle = draft.actionTitle {
              SheetConfirmToolbarItem(actionTitle, isEnabled: draft.canSubmit) { submit() }
            }
          }
      #endif
    }
    #if os(macOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SheetFooter(status: draft.status) {
          Button("Cancel", role: .cancel) { dismiss() }
          .settingsActionTint(theme)
          .keyboardShortcut(.cancelAction)
          .disabled(draft.isWorking)
          if let actionTitle = draft.actionTitle {
            Button(actionTitle) { submit() }
            .settingsActionTint(theme)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.canSubmit)
          }
        }
      }
      .sheetSize(.list)
      .themedSurface(.sheet)
    #else
      .sheetStatus(draft.status)
    #endif
    .interactiveDismissDisabled(draft.isWorking)
    .task(id: draft.signIn?.id) { await draft.follow() }
    .onChange(of: draft.pageToOpen) { _, page in
      if let page { openURL(page) }
    }
    .onChange(of: draft.isComplete) { _, complete in
      guard complete else { return }
      dismiss()
      Task { await onComplete() }
    }
    .onDisappear { Task { await draft.dismissed() } }
  }

  @ViewBuilder
  private var content: some View {
    if let signIn = draft.signIn {
      Form {
        errorSection
        Section { progress(signIn) }
      }
      .formStyle(.grouped)
    } else {
      #if os(macOS)
        VStack(spacing: 0) {
          List(filteredProviders, selection: providerSelection) { provider in
            HStack {
              Text(provider.name)
              Spacer()
              if configuredIds.contains(provider.id) {
                Text("Signed In").foregroundStyle(theme.textSecondary)
              }
            }
            .tag(provider.id)
          }
          .searchable(text: $search, placement: .toolbar, prompt: "Search providers")
          if draft.provider != nil {
            Divider()
            VStack(alignment: .leading, spacing: 12) {
              if let error = draft.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.statusError)
              }
              authentication
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
          }
        }
      #else
        Form {
          errorSection
          Section("Provider") {
            NavigationLink {
              HarnessProviderPicker(
                providers: draft.providers.map {
                  .init(id: $0.id, name: $0.name, isConfigured: configuredIds.contains($0.id))
                },
                selection: $draft.providerId)
            } label: {
              LabeledContent("Provider", value: draft.provider?.name ?? "Choose…")
            }
          }
          if draft.provider != nil {
            Section("Authentication") { authentication }
          }
        }
      #endif
    }
  }

  @ViewBuilder
  private var errorSection: some View {
    if let error = draft.errorMessage {
      Section {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(theme.statusError)
      }
    }
  }

  /// How to sign in to the chosen provider, and anything it asks first.
  @ViewBuilder
  private var authentication: some View {
    if let provider = draft.provider, provider.methods.count > 1 {
      Picker("Method", selection: $draft.methodId) {
        ForEach(provider.methods) { method in Text(method.label).tag(method.id) }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif
    } else if let method = draft.method {
      LabeledContent("Method", value: method.label)
    }
    ForEach(draft.visiblePrompts) { prompt in
      field(prompt, text: inputBinding(prompt.id))
    }
    if draft.method?.kind == .apiKey {
      SecureField("API Key", text: $draft.apiKey)
        .textContentType(.password)
        .privacySensitive()
        .onSubmit { submit() }
    }
  }

  /// The running sign-in: its page, its code, and what it's waiting for.
  @ViewBuilder
  private func progress(_ signIn: HarnessProviderSignIn) -> some View {
    if let instructions = signIn.instructions {
      Text(instructions).foregroundStyle(theme.textSecondary)
    }
    if let code = signIn.userCode {
      LabeledContent("Code") {
        HStack {
          Text(code).font(.headline.monospaced()).textSelection(.enabled)
          Button("Copy Code", systemImage: "doc.on.doc") { copy(code) }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
      }
    }
    if let page = signIn.url.flatMap(URL.init(string:)) {
      Button("Open Sign-In Page") { openURL(page) }
        #if os(macOS)
          .settingsActionTint(theme)
        #endif
    }
    if signIn.state == .waiting, let prompt = signIn.prompt {
      field(prompt, text: $draft.answer)
    }
  }

  @ViewBuilder
  private func field(_ prompt: HarnessProviderPrompt, text: Binding<String>) -> some View {
    switch prompt.kind {
    case .select:
      Picker(prompt.message, selection: text) {
        ForEach(prompt.options) { option in Text(option.label).tag(option.value) }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif
    case .secret:
      SecureField(prompt.placeholder ?? prompt.message, text: text)
        .privacySensitive()
        .onSubmit { submit() }
    case .text:
      TextField(prompt.placeholder ?? prompt.message, text: text)
        .onSubmit { submit() }
        #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        #endif
    }
  }

  private func inputBinding(_ key: String) -> Binding<String> {
    Binding(get: { draft.inputs[key] ?? "" }, set: { draft.inputs[key] = $0 })
  }

  private func submit() {
    Task { await draft.submit() }
  }

  private func copy(_ value: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(value, forType: .string)
    #else
      UIPasteboard.general.string = value
    #endif
  }

  #if os(macOS)
    private var filteredProviders: [HarnessProvider] {
      let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else { return draft.providers }
      return draft.providers.filter { $0.name.localizedStandardContains(query) }
    }

    private var providerSelection: Binding<String?> {
      Binding(get: { draft.providerId }, set: { if let id = $0 { draft.providerId = id } })
    }
  #endif
}
