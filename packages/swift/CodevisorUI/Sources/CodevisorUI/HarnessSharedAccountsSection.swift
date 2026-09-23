import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

/// Read-only inherited accounts sit alongside a machine's own providers.
public struct HarnessSharedAccountRows: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let source: HarnessSharedCredentials
  let excludedProviderIds: Set<String>

  public init(source: HarnessSharedCredentials, excludingProviderIds: Set<String> = []) {
    self.source = source
    self.excludedProviderIds = excludingProviderIds
  }

  public var body: some View {
    if let credentials = try? source.credentials(from: source.content(in: environment.configSync)) {
      ForEach(credentials.filter { !excludedProviderIds.contains($0.id) }) { credential in
        #if os(macOS)
          LabeledContent {
            Text("Shared").foregroundStyle(theme.textSecondary)
          } label: {
            Label(credential.name, systemImage: "key")
          }
        #else
          Label(credential.name, systemImage: "key")
        #endif
      }
    }
  }
}

/// The editable account list used only in global harness settings.
public struct HarnessSharedAccountsSection: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let source: HarnessSharedCredentials

  public init(source: HarnessSharedCredentials) { self.source = source }

  public var body: some View {
    Section {
      switch result {
      case .success(let credentials):
        ForEach(credentials) { credential in
          NavigationLink {
            HarnessSharedCredentialEditor(source: source, credential: credential)
          } label: {
            LabeledContent {
              Text(credential.kind).foregroundStyle(theme.textSecondary)
            } label: {
              Label(credential.name, systemImage: "key")
            }
          }
        }
        if credentials.isEmpty {
          Text("No accounts").foregroundStyle(theme.textSecondary)
        }
        #if os(macOS)
          if source != .devin {
            NavigationLink {
              HarnessSharedCredentialEditor(source: source, credential: nil)
            } label: {
              Label("Add API Key…", systemImage: "plus")
            }
          }
        #endif
      case .failure:
        Label("Shared credentials couldn’t be read.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(theme.textSecondary)
      }
    } footer: {
      #if os(macOS)
        if source == .devin { HarnessCredentialImportButton(source: source).font(.body) }
      #endif
    }
    #if os(iOS)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          if source == .devin {
            HarnessCredentialImportButton(source: source).labelStyle(.iconOnly)
          } else {
            NavigationLink {
              HarnessSharedCredentialEditor(source: source, credential: nil)
            } label: {
              Label("Add API Key", systemImage: "plus")
            }
          }
        }
      }
    #endif
  }

  private var result: Result<[HarnessSharedCredentials.Credential], Error> {
    Result { try source.credentials(from: source.content(in: environment.configSync)) }
  }
}

struct HarnessCredentialImportButton: View {
  @Environment(AppEnvironment.self) private var environment
  let source: HarnessSharedCredentials
  @State private var isImporting = false
  @State private var errorMessage: String?

  var body: some View {
    Button("Import Credentials…", systemImage: "plus") { isImporting = true }
      .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .data]) { result in
        do {
          let url = try result.get()
          let accessed = url.startAccessingSecurityScopedResource()
          defer { if accessed { url.stopAccessingSecurityScopedResource() } }
          let content = try String(contentsOf: url, encoding: .utf8)
          guard url.lastPathComponent == "credentials.toml",
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else {
            errorMessage = "Choose Devin’s credentials.toml file."
            return
          }
          environment.configSync.set(
            namespace: HarnessSharedCredentials.namespace, key: source.sourceKey, value: .string(content))
        } catch { errorMessage = "The credentials file couldn’t be imported." }
      }
      .alert(
        "Import Credentials", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
  }
}
