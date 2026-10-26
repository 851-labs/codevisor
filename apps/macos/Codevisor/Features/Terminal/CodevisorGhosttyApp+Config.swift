import AppKit
import Foundation
import GhosttyKit
import CodevisorCore
import SwiftUI
import os

extension CodevisorGhosttyApp {
  static func buildConfig(systemIsDark: Bool?) -> ghostty_config_t {
    let cfg = ghostty_config_new()
    if !AppPreview.rendersFixtures {
      ghostty_config_load_default_files(cfg)
    }
    if let overrideFile = writeOverrideConfig(systemIsDark: systemIsDark) {
      ghostty_config_load_file(cfg, overrideFile)
    }
    ghostty_config_finalize(cfg)
    guard let cfg else { fatalError("ghostty_config_new returned nil.") }
    return cfg
  }

  func reloadConfig() {
    let newConfig = Ghostty.Config(config: Self.buildConfig(systemIsDark: Self.currentSystemIsDark))
    ghostty_app_update_config(app, newConfig.config!)
    for view in surfaces.allObjects {
      if let surface = view.surface {
        ghostty_surface_update_config(surface, newConfig.config!)
      }
    }
    config = newConfig
  }

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
        Log.terminal.debug(
          "ghostty resources stamp write failed: \(String(describing: error), privacy: .public)")
      }
      return ghosttyDir.path
    } catch {
      fatalError("Failed to prepare Ghostty resources: \(error).")
    }
  }

  private static func writeOverrideConfig(systemIsDark: Bool?) -> String? {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("codevisor-ghostty.conf")
    var contents = """
      font-size = \(terminalFontSize)
      crash-report = false
      keybind = super+k=unbind

      """
    let isDark =
      systemIsDark
      ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    let background = Self.systemWindowBackgroundHex(isDark: isDark)
    let foreground = isDark ? "FFFFFF" : "000000"
    contents += "background = \(background)\n"
    contents += "background-opacity = 0.01\n"
    contents += "foreground = \(foreground)\n"
    contents += "cursor-color = cell-foreground\n"
    contents += "cursor-text = cell-background\n"
    do {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      Log.terminal.error("ghostty override config write failed: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

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
