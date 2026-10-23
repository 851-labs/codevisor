import SwiftUI
import CodevisorCore
import CodevisorUI

struct HarnessDetailSheet: View {
  let harness: ServerHarness

  @Environment(AppEnvironment.self) private var environment
  @Environment(\.settingsMachineId) private var settingsMachineId

  private var scopedServerId: String {
    settingsMachineId ?? environment.defaultComposerServerId
  }

  @Environment(\.dismiss) private var dismiss

  @State private var bundledApp: ServerHarnessBundledApp?
  @State private var isUpdatingBundledApp = false
  @State private var bundledAppError: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        details
      }
      .navigationTitle(harness.name)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SheetFooter {
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .sheetSize(.step)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(harness.name) details")
    .task { await loadBundledApp() }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 18)
          .frame(width: 30, height: 30)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
          .accessibilityHidden(true)
        Text("Built-in harness")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }

      Divider()

      detailRow("Version", value: harness.readiness.version ?? "Unknown")

      if let update = harness.updateInfo {
        if update.updateAvailable, let latest = update.latestVersion {
          HStack {
            Label("Update available", systemImage: "arrow.down.circle")
            Spacer()
            Text(
              update.installedVersion.map { "\($0) → \(latest)" } ?? latest
            )
            .foregroundStyle(.secondary)
          }
        } else if update.latestVersion != nil {
          HStack {
            Label("Up to date", systemImage: "checkmark.circle")
            Spacer()
            if let checkedAt = update.checkedAt {
              Text("Checked \(relativeTime(checkedAt))")
                .foregroundStyle(.secondary)
            }
          }
        }
        if let origin = update.installOrigin {
          detailRow("Installed via", value: originLabel(origin))
        }
      }

      if let path = harness.readiness.path {
        VStack(alignment: .leading, spacing: 4) {
          Text("Binary")
            .foregroundStyle(.secondary)
          Text(path)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
      }

      if let bundledApp {
        Divider()
        bundledAppBlock(bundledApp)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func bundledAppBlock(_ app: ServerHarnessBundledApp) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Also bundled with \(app.appName)")
          Text(bundledAppSubtitle(app))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isUpdatingBundledApp || harness.lifecycle?.phase == "updating" {
          ProgressView().controlSize(.small)
        } else if app.updateAvailable {
          Button("Update \(app.appName)…") { Task { await updateBundledApp() } }
        }
      }
      if app.updateAvailable {
        Text(
          "Replaces \(app.appName) with the verified build from its own update feed. Safe while the app is running — it uses the new version after its next launch."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      if let bundledAppError {
        Text(bundledAppError)
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func bundledAppSubtitle(_ app: ServerHarnessBundledApp) -> String {
    guard let installed = app.installedVersion else { return "Version unknown" }
    if app.updateAvailable, let latest = app.latestVersion {
      return "\(installed) → \(latest) available"
    }
    return "\(installed) · Up to date"
  }

  private func loadBundledApp() async {
    let serverId = scopedServerId
    bundledApp = try? await environment.machines.client(for: serverId)
      .bundledAppInfo(harnessId: harness.id)
  }

  private func updateBundledApp() async {
    isUpdatingBundledApp = true
    bundledAppError = nil
    defer { isUpdatingBundledApp = false }
    let serverId = scopedServerId
    do {
      try await environment.machines.client(for: serverId).updateBundledApp(harnessId: harness.id)
      environment.harnessCatalogDidChange(onServer: serverId)
      for _ in 0..<150 {
        try? await Task.sleep(for: .seconds(2))
        await loadBundledApp()
        if bundledApp?.updateAvailable != true { return }
      }
    } catch {
      bundledAppError = error.localizedDescription
    }
  }

  private func originLabel(_ origin: String) -> String {
    switch origin {
    case "npm": "npm"
    case "brew": "Homebrew"
    case "curl": "Installer script"
    case "appBundle": "Bundled with the ChatGPT app"
    case "standalone": "Standalone binary"
    default: "Unknown"
    }
  }

  private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private func relativeTime(_ isoTimestamp: String) -> String {
    guard let date = Self.timestampFormatter.date(from: isoTimestamp) else {
      return "recently"
    }
    return date.formatted(.relative(presentation: .named))
  }

  private func detailRow(_ title: String, value: String) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .textSelection(.enabled)
    }
  }
}

#Preview {
  HarnessDetailSheet(
    harness: ServerHarness(
      id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
      source: "registry", launchKind: "executable", enabled: true,
      readiness: ServerHarnessReadiness(
        state: "ready",
        path: "/Applications/ChatGPT.app/Contents/Resources/codex",
        version: "0.145.0-alpha.18"
      )
    ))
}
