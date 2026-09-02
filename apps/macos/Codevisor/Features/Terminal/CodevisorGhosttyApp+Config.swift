import AppKit
import Foundation
import GhosttyKit
import CodevisorCore
import CodevisorTheming
import SwiftUI
import os

extension CodevisorGhosttyApp {
    // MARK: - Config building (migrated from the previous GhosttyRuntime bridge)

    /// Builds a finalized raw config: default files + our override file (font,
    /// background, and — when themed — the full terminal palette).
    static func buildConfig(
        theme: TerminalPalette?,
        systemIsDark: Bool?
    ) -> ghostty_config_t {
        let cfg = ghostty_config_new()
        ghostty_config_load_default_files(cfg)
        if let overrideFile = writeOverrideConfig(theme: theme, systemIsDark: systemIsDark) {
            ghostty_config_load_file(cfg, overrideFile)
        }
        ghostty_config_finalize(cfg)
        guard let cfg else { fatalError("ghostty_config_new returned nil.") }
        return cfg
    }

    /// Rebuilds the config for the current theme and pushes it to the app and
    /// every live surface.
    func reloadConfig() {
        let newConfig = Ghostty.Config(
            config: Self.buildConfig(
                theme: Self.currentTheme,
                systemIsDark: Self.currentSystemIsDark
            ))
        ghostty_app_update_config(app, newConfig.config!)
        for view in surfaces.allObjects {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, newConfig.config!)
            }
        }
        // The old Ghostty.Config frees its ghostty_config_t in deinit.
        config = newConfig
    }

    /// Extracts the bundled Ghostty resources (terminfo + shell integration)
    /// into Application Support and returns the path to use as
    /// `GHOSTTY_RESOURCES_DIR` — the `ghostty` subdir, with `terminfo` adjacent
    /// as libghostty expects (it reads `dirname(resources)/terminfo`).
    static func prepareBundledResources() -> String {
        let fm = FileManager.default
        guard
            let tarball = Bundle.main.url(forResource: "ghostty-resources", withExtension: "tar.gz")
                ?? Bundle.main.resourceURL?.appendingPathComponent("ghostty-resources.tar.gz"),
            fm.fileExists(atPath: tarball.path)
        else {
            fatalError("Missing bundled ghostty-resources.tar.gz.")
        }

        let base = CodevisorAppVariant.applicationSupportURL(fileManager: fm)
            .appendingPathComponent("ghostty-resources", isDirectory: true)
        let ghosttyDir = base.appendingPathComponent("ghostty", isDirectory: true)

        // Extraction runs synchronously before ghostty_init (which captures
        // GHOSTTY_RESOURCES_DIR), so it can't move off the launch path — but
        // it CAN be skipped: a version stamp keyed on the app build and the
        // tarball's size/mtime makes the tar spawn a once-per-update cost
        // instead of a synchronous main-thread process on every launch.
        let stampURL = base.appendingPathComponent(".extracted-stamp")
        let attributes = try? fm.attributesOfItem(atPath: tarball.path)
        let tarballSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let tarballMtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let stamp = "\(bundleVersion)|\(tarballSize)|\(tarballMtime)"
        if fm.fileExists(atPath: ghosttyDir.path),
            let existing = try? String(contentsOf: stampURL, encoding: .utf8),
            existing == stamp
        {
            return ghosttyDir.path
        }

        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", tarball.path, "-C", base.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0, fm.fileExists(atPath: ghosttyDir.path) else {
                fatalError("Failed to extract Ghostty resources from \(tarball.path).")
            }
            do {
                try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            } catch {
                // Non-fatal: extraction just reruns on the next launch.
                Log.terminal.debug(
                    "ghostty resources stamp write failed: \(String(describing: error), privacy: .public)")
            }
            return ghosttyDir.path
        } catch {
            fatalError("Failed to prepare Ghostty resources: \(error).")
        }
    }

    /// Writes a tiny config file with our font + color overrides, and returns
    /// its path. With no theme, the terminal follows the system light/dark
    /// appearance; with a theme, it takes the theme's full palette.
    private static func writeOverrideConfig(
        theme: TerminalPalette?,
        systemIsDark: Bool?
    ) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codevisor-ghostty.conf")
        // crash-report = false: libghostty bundles its own sentry-native
        // crash reporter and starts it on a background "sentry-init" thread,
        // which intermittently segfaults at launch on macOS 26/27 betas.
        // Codevisor has its own crash reporting; Ghostty's stays off.
        var contents = """
            font-family = Menlo
            font-size = \(terminalFontSize)
            crash-report = false

            """
        if let theme {
            contents += "background = \(theme.background.hexString())\n"
            contents += "foreground = \(theme.foreground.hexString())\n"
            if let cursor = theme.cursorColor {
                contents += "cursor-color = \(cursor.hexString())\n"
            }
            if let selectionBg = theme.selectionBackground {
                contents += "selection-background = \(selectionBg.hexString())\n"
            }
            if let selectionFg = theme.selectionForeground {
                contents += "selection-foreground = \(selectionFg.hexString())\n"
            }
            // ANSI 0-15; slots the theme doesn't define keep Ghostty defaults.
            for (index, color) in theme.ansi.enumerated() {
                if let color {
                    contents += "palette = \(index)=\(color.hexString())\n"
                }
            }
        } else {
            let isDark =
                systemIsDark
                ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            // System theme: the terminal doesn't paint a background at all —
            // a near-zero opacity surface composites straight onto the
            // window's backdrop, so terminal panes sit on the SAME live
            // surface as the chat (including desktop wallpaper tinting,
            // which no fixed color can reproduce). The color still seeds
            // the ~1% blend, so keep it on-role.
            let background = Self.systemWindowBackgroundHex(isDark: isDark)
            let foreground = isDark ? "FFFFFF" : "000000"
            contents += "background = \(background)\n"
            contents += "background-opacity = 0.01\n"
            contents += "foreground = \(foreground)\n"
            contents += "cursor-color = \(foreground)\n"
        }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            // Ghostty falls back to its default fonts/colors without the file.
            Log.terminal.error("ghostty override config write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The system window-background color for an appearance, as a Ghostty
    /// hex value — the same surface the chat page sits on (see
    /// `Theme.windowBackground`).
    private static func systemWindowBackgroundHex(isDark: Bool) -> String {
        var hex = isDark ? "1E1E1E" : "FFFFFF"
        let appearance =
            NSAppearance(named: isDark ? .darkAqua : .aqua)
            ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                hex = String(
                    format: "%02X%02X%02X",
                    Int(round(rgb.redComponent * 255)),
                    Int(round(rgb.greenComponent * 255)),
                    Int(round(rgb.blueComponent * 255))
                )
            }
        }
        return hex
    }
}
