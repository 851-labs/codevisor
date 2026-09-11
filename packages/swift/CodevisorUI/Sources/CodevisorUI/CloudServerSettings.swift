import CodevisorCore
import SwiftUI

public struct CloudServerSettings: View {
  private let cloud: CloudAccountController
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @State private var isConnecting = false
  @State private var errorMessage: String?

  public init(cloud: CloudAccountController) { self.cloud = cloud }

  public var body: some View {
    Form {
      Section {
        LabeledContent("Current Server", value: cloud.serverURL.host() ?? cloud.serverURL.absoluteString)
      }
      Section {
        TextField("https://cloud.example.com", text: $address)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
          #endif
        Button(isConnecting ? "Connecting…" : "Connect") { connect() }
          .disabled(isConnecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if cloud.customServerURL != nil {
          Button("Use Default Server") { updateServer(nil) }
            .disabled(isConnecting)
        }
      } header: {
        Text("Self-Hosted Server")
      } footer: {
        Text("Connecting to a different server signs you out of your current account.")
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Cloud Server")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onAppear { address = cloud.customServerURL?.absoluteString ?? "" }
    .alert(
      "Couldn't Connect", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func connect() {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: withScheme), url.host() != nil,
      url.scheme == "https" || url.scheme == "http"
    else {
      errorMessage = "Enter a valid server address."
      return
    }
    updateServer(url)
  }

  private func updateServer(_ url: URL?) {
    isConnecting = true
    Task {
      defer { isConnecting = false }
      do {
        try await cloud.setCustomServer(url)
        await cloud.refreshAuthProviders()
        dismiss()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
