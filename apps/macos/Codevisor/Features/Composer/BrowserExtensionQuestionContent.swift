import AppKit
import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// Presents actionable Chrome setup on the Mac running the chat and a handoff
/// everywhere else. The underlying question remains server-owned, so a Chrome
/// connection from the host resolves the card on every connected client.
struct BrowserExtensionQuestionContent: View {
  @Environment(\.theme) private var theme
  @Bindable var controller: SessionController
  let question: QuestionSpec
  let canInstallLocally: Bool
  @Binding var didOpenBrowserExtensions: Bool
  let cancel: () -> Void
  let submitBack: (String) -> Void
  let performSetupAction: (String) -> Void
  let showDragStage: (Bool) -> Void

  @State private var archiveURL: URL?
  @State private var iconURL: URL?
  @State private var archiveError: String?
  @State private var isFileHovered = false

  private var isWaiting: Bool {
    question.presentation == .browserExtensionWaiting
  }

  var body: some View {
    Group {
      if canInstallLocally {
        localSetup
      } else {
        remoteHandoff
      }
    }
    .task(id: question.id) {
      await loadArchiveIfNeeded()
    }
  }

  private var localSetup: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Add Codevisor to Chrome")
          .font(.callout.weight(.semibold))
        Spacer(minLength: 12)
        dismissButton
      }

      Group {
        if didOpenBrowserExtensions {
          dragStage
        } else {
          openStage
        }
      }
      .frame(maxWidth: .infinity)

      HStack(spacing: 8) {
        waitingIndicator
        Spacer(minLength: 8)
        HStack(spacing: 4) {
          if didOpenBrowserExtensions {
            navButton("arrow.left", help: "Back to Open Chrome Extensions") {
              showDragStage(false)
            }
          } else {
            if let backOptionLabel = question.backOptionLabel {
              navButton("arrow.left", help: "Back") {
                submitBack(backOptionLabel)
              }
            }
            navButton("arrow.right", help: "Continue to Install Extension") {
              showDragStage(true)
            }
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(isWaiting ? "Finish Chrome setup" : "Connect Chrome")
  }

  private var remoteHandoff: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Finish Chrome setup on the other Mac")
          .font(.callout.weight(.semibold))
        Spacer(minLength: 12)
        dismissButton
      }

      VStack(spacing: 12) {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        VStack(spacing: 4) {
          Text("Open this chat on the Mac running it")
            .font(.callout.weight(.medium))
          Text(
            "Install the Codevisor extension from that Mac. This chat resumes automatically when Chrome connects."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(theme.cardQuietBackground)
      )

      HStack(spacing: 8) {
        waitingIndicator
        Spacer(minLength: 8)
        if let backOptionLabel = question.backOptionLabel {
          ComposerNavigationButton(
            systemImage: "arrow.left",
            help: "Back to Browser Choices",
            accessibilityLabel: "Back to Browser Choices"
          ) {
            submitBack(backOptionLabel)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Finish Chrome setup on the other Mac")
  }

  @ViewBuilder
  private var waitingIndicator: some View {
    if isWaiting {
      ProgressView()
        .controlSize(.small)
      Text("Waiting for Chrome…")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var openStage: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        chromeIcon
        Text("Open Chrome’s Extensions page")
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: 16)
        openChromeExtensionsButton
      }
      .frame(maxWidth: .infinity)

      VStack(spacing: 10) {
        HStack(spacing: 10) {
          chromeIcon
          Text("Open Chrome’s Extensions page")
            .font(.callout.weight(.medium))
        }
        openChromeExtensionsButton
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.cardQuietBackground)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Open Chrome’s Extensions page")
  }

  private var dragStage: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Text("Drag this file into Chrome’s Extensions page")
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: true, vertical: false)
        Spacer(minLength: 16)
        extensionFile
      }
      .frame(maxWidth: .infinity)

      VStack(spacing: 10) {
        Text("Drag this file into Chrome’s Extensions page")
          .font(.callout.weight(.medium))
          .multilineTextAlignment(.center)
        extensionFile
      }
      .frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.cardQuietBackground)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Drag Codevisor into the Chrome Extensions page")
  }

  private var chromeIcon: some View {
    Image("browser-chrome")
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: 36, height: 36)
      .accessibilityHidden(true)
  }

  private var openChromeExtensionsButton: some View {
    Button("Open Chrome Extensions") {
      performSetupAction("Open Extensions")
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
    .fixedSize()
  }

  @ViewBuilder
  private var extensionFile: some View {
    if let archiveURL {
      HStack(spacing: 8) {
        extensionFileIcon(archiveURL)
        VStack(alignment: .leading, spacing: 2) {
          Text("Codevisor for Chrome.zip")
            .font(.caption.weight(.medium))
            .lineLimit(1)
          Label("Drag", systemImage: "hand.draw")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 8)
      .frame(width: 208, height: 52, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(extensionFileBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(theme.border.opacity(0.7), lineWidth: 0.5)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .onHover { isFileHovered = $0 }
      .onDrag {
        NSItemProvider(contentsOf: archiveURL) ?? NSItemProvider()
      }
      .help("Drag the Codevisor extension into Chrome")
      .accessibilityLabel("Codevisor Chrome Extension zip file")
      .accessibilityHint("Drag this file onto the Chrome Extensions page")
    } else if archiveError != nil {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Text("Extension file unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Button("Retry") {
          Task { await loadArchiveIfNeeded(force: true) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      .frame(width: 208, height: 52)
    } else {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Preparing extension…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(width: 208, height: 52)
    }
  }

  private func extensionFileIcon(_ url: URL) -> some View {
    let icon = iconURL.flatMap(NSImage.init(contentsOf:)) ?? NSWorkspace.shared.icon(forFile: url.path)
    icon.size = NSSize(width: 48, height: 48)
    return Image(nsImage: icon)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: 36, height: 36)
      .accessibilityHidden(true)
  }

  private var extensionFileBackground: some ShapeStyle {
    if isFileHovered {
      return AnyShapeStyle(theme.cardHoverBackground)
    }
    return AnyShapeStyle(Color.clear)
  }

  private var dismissButton: some View {
    Button(action: cancel) {
      Image(systemName: "xmark")
        .font(.caption)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("Dismiss without answering (Esc)")
    .accessibilityLabel("Dismiss without answering")
    .accessibilityHint("Keyboard shortcut: Escape")
  }

  private func navButton(
    _ systemImage: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
        .frame(width: 26, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(help)
  }

  private func loadArchiveIfNeeded(force: Bool = false) async {
    guard canInstallLocally else { return }
    if !force, archiveURL != nil { return }
    archiveError = nil
    do {
      archiveURL = try await controller.browserExtensionArchive()
      iconURL = try? await controller.browserExtensionIcon()
    } catch {
      archiveURL = nil
      iconURL = nil
      archiveError = String(describing: error)
    }
  }
}
