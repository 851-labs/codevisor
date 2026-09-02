import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

struct IOSComposerSlashItem: Identifiable {
  let name: String
  let description: String
  let action: @MainActor () -> Void

  var id: String { name }
}

extension ComposerBar {
  /// The local command token at the caret. NSString keeps these offsets in
  /// the same UTF-16 coordinate space used by UITextView's selectedRange.
  var slashTokenRange: NSRange? {
    Self.slashTokenRange(in: text, selection: selection)
  }

  var slashQuery: String? {
    guard let range = slashTokenRange else { return nil }
    let value = text as NSString
    return value.substring(
      with: NSRange(location: range.location + 1, length: range.length - 1)
    ).lowercased()
  }

  var slashCommands: [IOSComposerSlashItem] {
    var commands: [IOSComposerSlashItem] = []
    if controller.hasPlanMode {
      commands.append(
        IOSComposerSlashItem(
          name: "plan",
          description: "Toggle plan mode"
        ) {
          Task { await controller.togglePlanMode() }
        }
      )
    }
    if controller.canEditGoal {
      commands.append(
        IOSComposerSlashItem(
          name: "goal",
          description: "Toggle goal mode"
        ) {
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
            controller.toggleGoalComposer()
          }
        }
      )
    }
    return commands
  }

  var slashMatches: [IOSComposerSlashItem] {
    guard let query = slashQuery else { return [] }
    if query.isEmpty { return slashCommands }
    let exact = slashCommands.filter { $0.name.lowercased() == query }
    let prefixed = slashCommands.filter { command in
      command.name.lowercased().hasPrefix(query)
        && !exact.contains(where: { $0.id == command.id })
    }
    return exact + prefixed
  }

  var isLoadingSlashCommands: Bool {
    slashQuery != nil && controller.isConnectingToHarness
  }

  var showsSlashCommandPopup: Bool {
    isLoadingSlashCommands || !slashMatches.isEmpty
  }

  /// Keep the first presentation out of the composer before SwiftUI's
  /// geometry callback arrives. Subsequent frames use the measured value,
  /// preserving Dynamic Type without a visible overlap.
  var slashPaletteHeight: CGFloat {
    if slashMenuContentHeight > 0 { return slashMenuContentHeight }
    if isLoadingSlashCommands { return 48 }
    let rows = CGFloat(slashMatches.count)
    return rows * 44 + max(0, rows - 1) * 2 + 12
  }

  @ViewBuilder
  var slashCommandPopup: some View {
    if isLoadingSlashCommands {
      HStack(spacing: 10) {
        ProgressView()
        Text("Connecting to harness…")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .frame(minHeight: 48)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        slashMenuContentHeight = $0
      }
      .composerGlassSurface(
        cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
        id: .commandPalette,
        in: glassNamespace
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Connecting to harness")
    } else {
      VStack(spacing: 2) {
        ForEach(slashMatches) { command in
          Button {
            acceptSlashCommand(command)
          } label: {
            HStack(spacing: 10) {
              Text("/\(command.name)")
                .fontWeight(.medium)
              Text(command.description)
                .lineLimit(1)
                .foregroundStyle(.secondary)
              Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("/\(command.name), \(command.description)")
        }
      }
      .padding(6)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        slashMenuContentHeight = $0
      }
      .composerGlassSurface(
        cornerRadius: ComposerGlassStyle.accessoryCornerRadius,
        id: .commandPalette,
        in: glassNamespace
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Slash commands")
      .accessibilityHint("Double tap a command to activate it")
    }
  }

  func submitOrAcceptSlashCommand() {
    guard !isLoadingSlashCommands else { return }
    if let command = slashMatches.first {
      acceptSlashCommand(command)
    } else {
      submitComposer()
    }
  }

  /// Local commands are removed in place before they run, preserving text
  /// on either side and leaving the keyboard focused for the next action.
  func acceptSlashCommand(_ command: IOSComposerSlashItem) {
    guard let range = slashTokenRange else { return }
    let updatedText = (text as NSString).replacingCharacters(in: range, with: "")
    text = updatedText
    controller.composerText = updatedText
    selection = NSRange(location: range.location, length: 0)
    command.action()
  }

  static func slashTokenRange(in text: String, selection: NSRange) -> NSRange? {
    guard selection.length == 0 else { return nil }
    let value = text as NSString
    let caret = min(selection.location, value.length)
    var index = caret
    while index > 0 {
      let unit = value.character(at: index - 1)
      if isSlashWhitespace(unit) { return nil }
      if unit == unichar(UInt8(ascii: "/")) {
        let slashIndex = index - 1
        guard slashIndex == 0 || isSlashWhitespace(value.character(at: slashIndex - 1)) else {
          return nil
        }
        return NSRange(location: slashIndex, length: caret - slashIndex)
      }
      index -= 1
    }
    return nil
  }

  private static func isSlashWhitespace(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
  }
}
