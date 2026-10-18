import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import os

struct NotificationsSettingsView: View {
  private struct SoundActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
  }

  @Environment(AppEnvironment.self) private var environment
  @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
  @State private var soundChoices: [SystemSoundChoice] = []
  @State private var testMessage: String?
  @State private var showingSoundImporter = false
  @State private var soundImportTarget: ChatAttentionKind?
  @State private var soundError: SoundActionError?

  private var settings: AppSettings { environment.settings.settings }
  private var customSoundStore: CustomSoundStore { CustomSoundStore() }
  private var customSoundChoices: [SystemSoundChoice] { soundChoices.filter(\.isCustom) }

  var body: some View {
    Form {
      notificationsSection
      deliverySection
      soundsSection
      customSoundsSection
      testSection
    }
    .formStyle(.grouped)
    .fileImporter(
      isPresented: $showingSoundImporter,
      allowedContentTypes: [.audio]
    ) { result in
      handleSoundImport(result)
    }
    .alert(
      soundError?.title ?? "",
      isPresented: Binding(
        get: { soundError != nil },
        set: { if !$0 { soundError = nil } }
      ),
      presenting: soundError
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { error in
      Text(error.message)
    }
    .task {
      refreshSoundChoices()
      await refreshAuthorizationStatus()
    }
  }

  private var notificationsSection: some View {
    Section {
      Toggle(isOn: notificationsEnabled) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Chat notifications")
          Text("Get notified when a chat finishes or needs your input.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)
    }
  }

  private var deliverySection: some View {
    Section {
      Toggle("Show notifications when Codevisor isn't active", isOn: systemNotificationsEnabled)
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!settings.notificationsEnabled)

      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("System notifications")
          Text(authorizationDescription)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(authorizationButtonTitle) {
          handleAuthorizationButton()
        }
        .disabled(!settings.notificationsEnabled || !settings.systemNotificationsEnabled)
      }
    } header: {
      Text("Delivery")
    }
  }

  private var soundsSection: some View {
    Section {
      Toggle("Play sounds", isOn: soundsEnabled)
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!settings.notificationsEnabled)

      soundRow(
        title: "Chat finished",
        selection: chatFinishedSound,
        kind: .finished
      )
      .disabled(!settings.notificationsEnabled || !settings.notificationSoundsEnabled)

      soundRow(
        title: "Action required",
        selection: actionRequiredSound,
        kind: .actionRequired
      )
      .disabled(!settings.notificationsEnabled || !settings.notificationSoundsEnabled)
    } header: {
      Text("Sounds")
    }
  }

  private var customSoundsSection: some View {
    Section {
      if customSoundChoices.isEmpty {
        Text("No custom sounds")
          .foregroundStyle(.secondary)
      } else {
        ForEach(customSoundChoices) { sound in
          customSoundRow(sound)
        }
      }
    } header: {
      Text("Custom Sounds")
    } footer: {
      SettingsListActions {
        Button("Add Sound…") {
          soundImportTarget = nil
          showingSoundImporter = true
        }
      }
    }
  }

  private var testSection: some View {
    Section("Test") {
      HStack {
        Button("Send Test Notification") {
          Task { await sendTestNotification() }
        }
        Spacer()
        if let testMessage {
          Text(testMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var notificationsEnabled: Binding<Bool> {
    Binding(
      get: { settings.notificationsEnabled },
      set: { enabled in
        environment.settings.setNotificationsEnabled(enabled)
        if enabled, settings.systemNotificationsEnabled {
          Task {
            await ChatNotificationManager.shared.prepareAuthorizationIfNeeded()
            await refreshAuthorizationStatus()
          }
        }
      }
    )
  }

  private var systemNotificationsEnabled: Binding<Bool> {
    Binding(
      get: { settings.systemNotificationsEnabled },
      set: { enabled in
        environment.settings.setSystemNotificationsEnabled(enabled)
        if enabled {
          Task {
            await ChatNotificationManager.shared.prepareAuthorizationIfNeeded()
            await refreshAuthorizationStatus()
          }
        }
      }
    )
  }

  private var soundsEnabled: Binding<Bool> {
    Binding(
      get: { settings.notificationSoundsEnabled },
      set: { environment.settings.setNotificationSoundsEnabled($0) }
    )
  }

  private var chatFinishedSound: Binding<String> {
    Binding(
      get: { settings.chatFinishedSoundPath },
      set: { environment.settings.setChatFinishedSoundPath($0) }
    )
  }

  private var actionRequiredSound: Binding<String> {
    Binding(
      get: { settings.actionRequiredSoundPath },
      set: { environment.settings.setActionRequiredSoundPath($0) }
    )
  }

  private func soundRow(
    title: String,
    selection: Binding<String>,
    kind: ChatAttentionKind
  ) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .foregroundStyle(.primary)
      Spacer(minLength: 20)
      Menu {
        let custom = customSoundChoices
        let system = soundChoices.filter { !$0.isCustom }
        if custom.isEmpty {
          soundMenuItems(system, selection: selection)
          Divider()
          Button("Add Custom Sound…") {
            soundImportTarget = kind
            showingSoundImporter = true
          }
        } else {
          Section("System") {
            soundMenuItems(system, selection: selection)
          }
          Section("Custom") {
            soundMenuItems(custom, selection: selection)
            Button("Add Custom Sound…") {
              soundImportTarget = kind
              showingSoundImporter = true
            }
          }
        }
      } label: {
        HStack(spacing: 10) {
          Text(soundName(for: selection.wrappedValue))
            .foregroundStyle(.primary)
            .lineLimit(1)

          ZStack {
            Circle()
              .fill(Color.secondary.opacity(0.12))
              .frame(width: 20, height: 20)
            Image(systemName: "chevron.up.chevron.down")
              .font(.system(size: Typography.IconSize.compact, weight: .semibold))
              .foregroundStyle(.primary)
          }
        }
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize(horizontal: true, vertical: false)

      Button {
        ChatNotificationManager.shared.playPreview(kind: kind)
      } label: {
        ZStack {
          Circle()
            .strokeBorder(Color.secondary.opacity(0.75), lineWidth: 1)
            .frame(width: 20, height: 20)
          Image(systemName: "play.fill")
            .font(.system(size: Typography.IconSize.compact, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Play \(title.lowercased()) sound")
      .accessibilityLabel("Test \(title.lowercased()) sound")
    }
  }

  @ViewBuilder
  private func soundMenuItems(_ choices: [SystemSoundChoice], selection: Binding<String>) -> some View {
    ForEach(choices) { sound in
      Button {
        selection.wrappedValue = sound.path
      } label: {
        if sound.path == selection.wrappedValue {
          Label(sound.name, systemImage: "checkmark")
        } else {
          Text(sound.name)
        }
      }
    }
  }

  private func customSoundRow(_ sound: SystemSoundChoice) -> some View {
    HStack {
      Text(sound.name)
        .foregroundStyle(.primary)
      Spacer()
      Button {
        ChatNotificationManager.shared.playSample(at: sound.path)
      } label: {
        Image(systemName: "play.circle")
      }
      .buttonStyle(.borderless)
      .help("Play \(sound.name)")
      .accessibilityLabel("Play \(sound.name)")
      Button {
        deleteCustomSound(sound)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove this sound")
      .accessibilityLabel("Remove \(sound.name)")
    }
  }

  private func handleSoundImport(_ result: Result<URL, any Error>) {
    let target = soundImportTarget
    soundImportTarget = nil
    guard case let .success(url) = result else { return }
    do {
      let imported = try customSoundStore.importSound(from: url)
      refreshSoundChoices()
      switch target {
      case .finished:
        environment.settings.setChatFinishedSoundPath(imported.path)
      case .actionRequired:
        environment.settings.setActionRequiredSoundPath(imported.path)
      case nil:
        break
      }
      ChatNotificationManager.shared.playSample(at: imported.path)
    } catch {
      Log.attachments.error("Importing custom sound failed: \(String(describing: error), privacy: .public)")
      soundError = SoundActionError(
        title: "Couldn't Add the Sound",
        message: ErrorReporter.userFacingMessage(for: error)
      )
    }
  }

  private func deleteCustomSound(_ sound: SystemSoundChoice) {
    do {
      try customSoundStore.deleteSound(at: URL(fileURLWithPath: sound.path))
    } catch {
      Log.attachments.error(
        "Deleting custom sound \(sound.path, privacy: .public) failed: \(String(describing: error), privacy: .public)"
      )
      soundError = SoundActionError(
        title: "Couldn't Remove the Sound",
        message: ErrorReporter.userFacingMessage(for: error)
      )
      return
    }
    if settings.chatFinishedSoundPath == sound.path {
      environment.settings.setChatFinishedSoundPath(AppSettings.defaultNotificationSoundPath)
    }
    if settings.actionRequiredSoundPath == sound.path {
      environment.settings.setActionRequiredSoundPath(AppSettings.defaultNotificationSoundPath)
    }
    refreshSoundChoices()
  }

  private func soundName(for path: String) -> String {
    soundChoices.first { $0.path == path }?.name
      ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  private var authorizationDescription: String {
    switch authorizationStatus {
    case .notDetermined: "Codevisor hasn't asked for permission yet."
    case .denied: "Off in System Settings."
    case .authorized, .provisional: "Allowed by macOS."
    @unknown default: "Managed by macOS."
    }
  }

  private var authorizationButtonTitle: String {
    switch authorizationStatus {
    case .notDetermined: "Allow…"
    default: "Notification Settings…"
    }
  }

  private func handleAuthorizationButton() {
    if authorizationStatus == .notDetermined {
      Task {
        _ = await ChatNotificationManager.shared.requestAuthorization()
        await refreshAuthorizationStatus()
      }
    } else {
      ChatNotificationManager.shared.openSystemNotificationSettings()
    }
  }

  private func refreshSoundChoices() {
    soundChoices = SystemSoundCatalog.availableSounds(including: [
      settings.chatFinishedSoundPath,
      settings.actionRequiredSoundPath,
    ])
  }

  private func refreshAuthorizationStatus() async {
    authorizationStatus = await ChatNotificationManager.shared.authorizationStatus()
  }

  private func sendTestNotification() async {
    let sent = await ChatNotificationManager.shared.sendTestNotification(kind: .finished)
    testMessage = sent ? "Test sent" : "Notifications are off in System Settings"
    await refreshAuthorizationStatus()
    try? await Task.sleep(for: .seconds(3))
    testMessage = nil
  }
}
