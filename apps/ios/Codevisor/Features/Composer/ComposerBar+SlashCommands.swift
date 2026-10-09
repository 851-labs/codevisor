import ACPKit
import CodevisorCore
import CodevisorUI
import Foundation
import SwiftUI

/// A palette row: a skill (accepted by rewriting the token to the harness's
/// exact invocation) or a local command (accepted by excising the token and
/// running its action).
struct IOSComposerSlashItem: Identifiable {
  let name: String
  let description: String
  /// Present only on skills: where the skill comes from.
  var source: SessionSkillSource? = nil
  /// Present only on skills: the text that replaces the token.
  var insertion: String? = nil
  /// Present only on local commands (/plan, /goal).
  var action: (@MainActor () -> Void)? = nil

  /// What the row shows as its title: what accepting it inserts.
  var title: String { insertion ?? "/\(name)" }

  /// A harness may offer a skill with a local command's name, so the two
  /// kinds never share an identity.
  var id: String { action == nil ? "skill:\(title)" : "command:\(name)" }
}

extension IOSComposerSlashItem {
  init(skill: SessionSkill) {
    self.init(
      name: skill.name,
      description: skill.description ?? "",
      source: skill.source,
      insertion: skill.invocation
    )
  }
}

extension ComposerBar {
  /// Tallest the palette grows before it scrolls (~6 rows).
  static let slashMenuMaxHeight: CGFloat = 286

  /// The "/" or "$" token at the caret. NSString keeps these offsets in
  /// the same UTF-16 coordinate space used by UITextView's selectedRange.
  var slashToken: ComposerSlashToken? {
    ComposerSlashToken(in: text, selection: selection)
  }

  /// Local commands run in the app itself: /plan and /goal toggle their
  /// composer modes.
  var localSlashCommands: [IOSComposerSlashItem] {
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

  /// Skills only (the harness's own plus Codevisor store skills), never
  /// harness commands; matching local commands lead for "/" alone, since
  /// "$" is Codex's skill syntax.
  var slashMatches: [IOSComposerSlashItem] {
    guard let token = slashToken else { return [] }
    let skills = ComposerSkillCatalog.matches(controller.composerSkills, query: token.query)
      .map(IOSComposerSlashItem.init(skill:))
    guard token.trigger == .slash else { return skills }
    let commands = localSlashCommands
    let query = token.query
    let exact = commands.filter { $0.name.lowercased() == query }
    let prefixed = commands.filter { command in
      command.name.lowercased().hasPrefix(query)
        && !exact.contains(where: { $0.id == command.id })
    }
    return exact + prefixed + skills
  }

  var isLoadingSlashCommands: Bool {
    slashToken != nil && controller.isConnectingToHarness
  }

  var showsSlashCommandPopup: Bool {
    isLoadingSlashCommands || !slashMatches.isEmpty
  }

  /// Keep the first presentation out of the composer before SwiftUI's
  /// geometry callback arrives. Subsequent frames use the measured value,
  /// preserving Dynamic Type without a visible overlap.
  var slashPaletteHeight: CGFloat {
    if isLoadingSlashCommands { return slashMenuContentHeight > 0 ? slashMenuContentHeight : 48 }
    if slashMenuContentHeight > 0 { return min(slashMenuContentHeight, Self.slashMenuMaxHeight) }
    let rows = CGFloat(slashMatches.count)
    return min(rows * 44 + max(0, rows - 1) * 2 + 12, Self.slashMenuMaxHeight)
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
        shape: cardStyle.shape,
        id: .commandPalette,
        in: glassNamespace
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Connecting to harness")
    } else {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(slashMatches) { command in
            slashCommandRow(command)
          }
        }
        .padding(6)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          slashMenuContentHeight = $0
        }
      }
      .frame(height: slashPaletteHeight)
      .clipShape(cardStyle.shape)
      .composerGlassSurface(
        shape: cardStyle.shape,
        id: .commandPalette,
        in: glassNamespace
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Commands and skills")
      .accessibilityHint("Double tap an item to insert or run it")
    }
  }

  private func slashCommandRow(_ command: IOSComposerSlashItem) -> some View {
    Button {
      acceptSlashCommand(command)
    } label: {
      HStack(spacing: 10) {
        Text(command.title)
          .fontWeight(.medium)
          .lineLimit(1)
          // Long descriptions truncate first; the title and its source
          // label stay whole.
          .layoutPriority(1)
        Text(command.description)
          .lineLimit(1)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if let source = command.source {
          Text(source.paletteLabel)
            .lineLimit(1)
            .foregroundStyle(.tertiary)
            .layoutPriority(1)
        }
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerHighlight(RoundedRectangle(cornerRadius: 12))
    .accessibilityLabel(
      [command.title, command.description, command.source?.paletteLabel ?? ""]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    )
  }

  func submitOrAcceptSlashCommand() {
    guard !isLoadingSlashCommands else { return }
    if let command = slashMatches.first {
      acceptSlashCommand(command)
    } else {
      submitComposer()
    }
  }

  /// Accepts in place, preserving text on either side and leaving the
  /// keyboard focused: skills rewrite the token to their invocation; local
  /// commands excise it before they run.
  func acceptSlashCommand(_ command: IOSComposerSlashItem) {
    guard let range = slashToken?.range else { return }
    let replacement = command.action == nil ? "\(command.title) " : ""
    let updatedText = (text as NSString).replacingCharacters(in: range, with: replacement)
    // The editor applies it undoably, so undo puts the typed token back.
    pendingTextEdit = ComposerTextEdit(range: range, replacement: replacement)
    text = updatedText
    controller.composerText = updatedText
    selection = NSRange(location: range.location + (replacement as NSString).length, length: 0)
    command.action?()
  }
}
