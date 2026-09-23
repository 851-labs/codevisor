import CodevisorCore
import SwiftUI

struct HarnessSharedCredentialEditor: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.dismiss) private var dismiss
  let source: HarnessSharedCredentials
  let credential: HarnessSharedCredentials.Credential?

  @State private var providerId = ""
  @State private var customProviderId = ""
  @State private var apiKey = ""
  @State private var providers: [String: String] = [:]
  @State private var errorMessage: String?
  @State private var confirmsRemoval = false

  private var effectiveProviderId: String {
    credential?.id ?? (source.hasProviders ? (providerId.isEmpty ? customProviderId : providerId) : "openai")
  }

  private var canReplace: Bool { credential?.canReplaceKey ?? true }

  var body: some View {
    Form {
      if canReplace {
        Section {
          if let credential {
            LabeledContent("Provider", value: credential.name)
          } else if source.hasProviders {
            NavigationLink {
              HarnessCredentialProviderPicker(providers: providers, selection: $providerId)
            } label: {
              LabeledContent("Provider", value: providers[providerId] ?? "Other…")
            }
            if providerId.isEmpty {
              TextField("Provider ID", text: $customProviderId, prompt: Text("e.g. openai"))
                .autocorrectionDisabled()
                #if os(iOS)
                  .textInputAutocapitalization(.never)
                #endif
            }
          } else {
            LabeledContent("Provider", value: "OpenAI")
          }
          SecureField(credential == nil ? "API Key" : "New API Key", text: $apiKey)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
            #endif
        }
      } else if let credential {
        Section {
          LabeledContent("Provider", value: credential.name)
          LabeledContent("Type", value: credential.kind)
        }
      }
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(theme.statusError)
        }
      }
      #if os(macOS)
        if credential != nil {
          Section { Button("Remove Credential…", role: .destructive) { confirmsRemoval = true } }
        }
      #endif
    }
    .formStyle(.grouped)
    .navigationTitle(credential?.name ?? "Add API Key")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      #if os(iOS)
        if credential != nil {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button("Remove Credential…", systemImage: "trash", role: .destructive) { confirmsRemoval = true }
            } label: {
              Label("Credential Actions", systemImage: "ellipsis")
            }
          }
        }
      #endif
      if canReplace {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            save()
          } label: {
            #if os(iOS)
              Label("Save", systemImage: "checkmark").labelStyle(.iconOnly)
            #else
              Text("Save")
            #endif
          }
          .disabled(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || effectiveProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .task { await loadProviders() }
    .alert("Remove Shared Credential?", isPresented: $confirmsRemoval) {
      Button("Remove", role: .destructive) { remove() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Removes this credential across your machines. Local sign-ins are kept.")
    }
  }

  private func save() {
    do {
      let sync = environment.configSync
      let content = try source.replacingKey(in: source.content(in: sync), providerId: effectiveProviderId, key: apiKey)
      sync.set(namespace: HarnessSharedCredentials.namespace, key: source.sourceKey, value: .string(content))
      apiKey = ""
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  private func remove() {
    guard let credential else { return }
    do {
      let sync = environment.configSync
      if let content = try source.removing(from: source.content(in: sync), providerId: credential.id) {
        sync.set(namespace: HarnessSharedCredentials.namespace, key: source.sourceKey, value: .string(content))
      } else {
        sync.remove(namespace: HarnessSharedCredentials.namespace, key: source.sourceKey)
      }
      dismiss()
    } catch { errorMessage = error.localizedDescription }
  }

  private func loadProviders() async {
    guard credential == nil, source.hasProviders, providers.isEmpty else { return }
    // Common IDs remain usable offline. A reachable harness supplies its full catalog.
    for id in ["anthropic", "openai", "google", "openrouter", "groq", "xai"] {
      providers[id] = HarnessSharedCredentials.providerName(id)
    }
    providerId = "openai"
    guard let host = await HarnessFleet.findSharedHost(harnessId: source.rawValue, environment: environment)
    else { return }
    let client = environment.machines.client(for: host.machineId)
    if source == .pi, let catalog = try? await client.listPiAuthProviders() {
      for provider in catalog where provider.methods.contains("api_key") { providers[provider.id] = provider.name }
    }
    if source == .opencode,
      let accounts = try? await client.listHarnessAccounts(harnessId: source.rawValue),
      let account = accounts.first(where: { $0.profileKind == "default" }),
      let catalog = try? await client.listOpenCodeAuthProviders(accountId: account.id)
    {
      for provider in catalog where provider.methods.contains(where: { $0.type == "api" && $0.prompts.isEmpty }) {
        providers[provider.id] = provider.name
      }
    }
  }
}
