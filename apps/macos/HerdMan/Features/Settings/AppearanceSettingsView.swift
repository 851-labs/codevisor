import HerdManCore
import HerdManTheming
import SwiftUI
import UniformTypeIdentifiers

/// The Settings ▸ Appearance tab: color mode, per-scheme theme pickers over
/// the System/Pierre/Shiki/Custom catalog, a live preview, and custom theme
/// import/removal.
struct AppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showingImporter = false
    @State private var importError: String?

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
                                try? manager.deleteCustomTheme(id: descriptor.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this theme")
                        }
                    }
                }
                Button("Import Theme…") { showingImporter = true }
            } header: {
                Text("Custom Themes")
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            guard case let .success(url) = result else { return }
            do {
                try manager.importTheme(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert(
            "Couldn't Import Theme",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Pickers

    private func themePicker(label: String, scheme: ThemeDescriptor.SchemeType) -> some View {
        LabeledContent(label) {
            Menu {
                let groups = ThemeDescriptor.Group.allCases
                ForEach(groups, id: \.self) { group in
                    let themes = manager.availableThemes.filter {
                        $0.group == group && $0.type == scheme
                    }
                    if !themes.isEmpty {
                        Section(group.displayName) {
                            ForEach(themes) { descriptor in
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
