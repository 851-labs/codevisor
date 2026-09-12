import CodevisorCore
import SwiftUI

public struct PluginSafetyButton: View {
  let pluginId: String
  let name: String
  @State private var showingReport = false

  public init(pluginId: String, name: String) {
    self.pluginId = pluginId
    self.name = name
  }

  public var body: some View {
    Button {
      showingReport = true
    } label: {
      Image(systemName: "flag")
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Report \(name)")
    .help("Report Plugin")
    .sheet(isPresented: $showingReport) {
      PluginReportSheet(pluginId: pluginId, name: name)
    }
  }
}

private struct PluginReportSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let pluginId: String
  let name: String
  @State private var reportId = UUID()
  @State private var reason = "Harmful content"
  @State private var details = ""
  @State private var working = false
  @State private var sent = false
  @State private var confirmBlock = false
  @State private var errorMessage: String?

  private var publisher: String { String(pluginId.split(separator: ".").first ?? "") }
  private var isBlocked: Bool { environment.pluginAccess.blockedPublishers.contains(publisher) }

  var body: some View {
    NavigationStack {
      Form {
        if sent {
          Section {
            Label("Report sent", systemImage: "checkmark.circle")
            Text("Thanks. We’ll review it.").foregroundStyle(.secondary)
          }
        } else {
          Section {
            Text(name).font(.headline)
            Picker("Reason", selection: $reason) {
              ForEach(["Harmful content", "Privacy or security", "Spam or abuse", "Other"], id: \.self) { Text($0) }
            }
            TextField("Details (optional)", text: $details, axis: .vertical)
              .lineLimit(3...5)
              .onChange(of: details) { _, value in details = String(value.prefix(2000)) }
          } footer: {
            Text("Your report goes to the Codevisor team.")
          }
        }
        #if os(iOS)
          Section {
            Button(isBlocked ? "Unblock Publisher" : "Block Publisher", role: isBlocked ? nil : .destructive) {
              confirmBlock = true
            }
          } footer: {
            Text("Hide this publisher’s plugins and prevent them from opening on iOS.")
          }
        #endif
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .disabled(working)
      .navigationTitle("Report Plugin")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(sent ? "Done" : "Cancel") { dismiss() }.disabled(working)
        }
        ToolbarItem(placement: .confirmationAction) {
          if working {
            ProgressView()
          } else if !sent {
            Button("Send") { Task { await send() } }
          }
        }
      }
    }
    #if os(macOS)
      .frame(width: 440, height: 340)
    #endif
    .interactiveDismissDisabled(working)
    .confirmationDialog(
      isBlocked ? "Unblock \(publisher)?" : "Block \(publisher)?", isPresented: $confirmBlock, titleVisibility: .visible
    ) {
      Button(isBlocked ? "Unblock Publisher" : "Block Publisher", role: isBlocked ? nil : .destructive) {
        Task { await toggleBlock() }
      }
    }
    .task { _ = try? await environment.pluginAccess.snapshot() }
  }

  private func send() async {
    working = true
    defer { working = false }
    do {
      try await environment.pluginAccess.report(
        id: reportId, pluginId: pluginId, name: name, reason: reason, details: details)
      sent = true
      errorMessage = nil
    } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
  }

  private func toggleBlock() async {
    working = true
    defer { working = false }
    do {
      try await environment.pluginAccess.setPublisherBlocked(publisher, blocked: !isBlocked)
      dismiss()
    } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
  }
}
