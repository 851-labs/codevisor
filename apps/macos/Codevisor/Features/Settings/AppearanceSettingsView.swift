import CodevisorCore
import CodevisorTheming
import SwiftUI
import UniformTypeIdentifiers
import os

/// The Settings ▸ Appearance tab: color mode, per-scheme theme pickers over
/// the System/Pierre/Shiki/Custom catalog, a live preview, and custom theme
/// import/removal.
struct AppearanceSettingsView: View {
    /// A failed theme action (import/delete), pending display in an alert.
    private struct ThemeError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var showingImporter = false
    @State private var themeError: ThemeError?

    private var manager: ThemeManager { environment.theme }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: modeBinding) {
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                    Text("System").tag(ThemeMode.system)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Mode")
            }

            Section {
                themePicker(label: "Light theme", scheme: .light)
                themePicker(label: "Dark theme", scheme: .dark)
            } header: {
                Text("Themes")
            } footer: {
                Text("Any VSCode or Shiki color theme works. The theme styles the whole app, including the terminal and code blocks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                let customThemes = manager.availableThemes.filter { $0.group == .custom }
                if customThemes.isEmpty {
                    Text("No imported themes")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customThemes) { descriptor in
                        HStack {
                            ThemeSwatchView(palette: manager.palette(forThemeId: descriptor.id))
                            Text(descriptor.displayName)
                            Text(descriptor.type == .dark ? "Dark" : "Light")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                do {
                                    try manager.deleteCustomTheme(id: descriptor.id)
                                } catch {
                                    Log.theming.error("Deleting custom theme \(descriptor.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                                    themeError = ThemeError(
                                        title: "Couldn't Delete the Theme",
                                        message: ErrorReporter.userFacingMessage(for: error)
                                    )
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .settingsActionTint(theme)
                            .help("Remove this theme")
                            .accessibilityLabel("Remove \(descriptor.displayName)")
                        }
                    }
                }
                Button("Import Theme…") { showingImporter = true }
                    .settingsActionTint(theme)
            } header: {
                Text("Custom Themes")
            }
        }
        .settingsPaneFormStyle(theme)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            guard case let .success(url) = result else { return }
            do {
                try manager.importTheme(from: url)
            } catch {
                Log.theming.error("Importing theme failed: \(String(describing: error), privacy: .public)")
                themeError = ThemeError(
                    title: "Couldn't Import Theme",
                    message: ErrorReporter.userFacingMessage(for: error)
                )
            }
        }
        .alert(
            themeError?.title ?? "",
            isPresented: Binding(
                get: { themeError != nil },
                set: { if !$0 { themeError = nil } }
            ),
            presenting: themeError
        ) { _ in
            Button("OK", role: .cancel) {}
                .settingsActionTint(theme)
        } message: { error in
            Text(error.message)
        }
    }

    // MARK: - Pickers

    private func themePicker(label: String, scheme: ThemeDescriptor.SchemeType) -> some View {
        LabeledContent(label) {
            Menu {
                // One flat list in catalog order (system, pierre, shiki,
                // custom) — no group headers or dividers.
                ForEach(manager.availableThemes.filter { $0.type == scheme }) { descriptor in
                    Button {
                        manager.setThemeId(descriptor.id, for: scheme)
                    } label: {
                        if descriptor.id == manager.themeId(for: scheme) {
                            Label(descriptor.displayName, systemImage: "checkmark")
                        } else {
                            Text(descriptor.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    ThemeSwatchView(
                        palette: manager.palette(forThemeId: manager.themeId(for: scheme)))
                    Text(selectedDisplayName(for: scheme))
                }
            }
            .menuStyle(.borderlessButton)
            .settingsActionTint(theme)
            .fixedSize()
        }
    }

    private func selectedDisplayName(for scheme: ThemeDescriptor.SchemeType) -> String {
        let id = manager.themeId(for: scheme)
        return manager.availableThemes.first { $0.id == id }?.displayName ?? id
    }

    private var modeBinding: Binding<ThemeMode> {
        Binding(get: { manager.mode }, set: { manager.setMode($0) })
    }
}

/// Five small squares summarizing a palette: window, sidebar, text, accent,
/// status. System entries (nil palette) render the current dynamic colors.
struct ThemeSwatchView: View {
    let palette: DerivedPalette?

    var body: some View {
        let theme = Theme(palette: palette)
        HStack(spacing: 2) {
            swatch(theme.windowBackground)
            swatch(Color(rgba: palette?.sidebarBackground) ?? Color(nsColor: .underPageBackgroundColor))
            swatch(theme.textPrimary)
            swatch(theme.accent)
            swatch(theme.statusOK)
        }
    }

    private func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

extension Color {
    /// Optional-friendly RGBA bridge used by the swatches.
    fileprivate init?(rgba: RGBA?) {
        guard let rgba else { return nil }
        self.init(rgba: rgba)
    }
}
