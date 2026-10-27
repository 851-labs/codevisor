import CodevisorCore
import SwiftUI

public struct PluginReportSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let subject: PluginModerationSubject
  @State private var reportId = UUID()
  @State private var reason = Self.reasons[0]
  @State private var details = ""
  @State private var working = false
  @State private var sent = false
  @State private var errorMessage: String?

  private static let reasons = ["Harmful content", "Privacy or security", "Spam or abuse", "Other"]
  private static let detailLimit = 2000

  public init(subject: PluginModerationSubject) {
    self.subject = subject
  }

  public var body: some View {
    NavigationStack {
      Form {
        if sent {
          Section {
            Label("Report sent", systemImage: "checkmark.circle")
            Text("Thanks. We’ll review it.").foregroundStyle(.secondary)
          }
        } else {
          reportSection
        }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .disabled(working)
      .navigationTitle("Report Plugin")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar { toolbar }
    }
    #if os(macOS)
      .frame(width: 440, height: 320)
    #endif
    .interactiveDismissDisabled(working)
  }

  private var reportSection: some View {
    Section {
      Text(subject.name)
      Picker("Reason", selection: $reason) {
        ForEach(Self.reasons, id: \.self) { Text($0) }
      }
      TextField("Details (optional)", text: $details, axis: .vertical)
        .lineLimit(3...5)
        .onChange(of: details) { _, value in details = String(value.prefix(Self.detailLimit)) }
    } footer: {
      Text("Your report goes to the Codevisor team.")
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
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

  private func send() async {
    working = true
    defer { working = false }
    do {
      try await environment.pluginAccess.report(id: reportId, subject: subject, reason: reason, details: details)
      sent = true
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
