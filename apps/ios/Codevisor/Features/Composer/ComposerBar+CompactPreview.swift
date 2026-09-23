import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Compact preview and expanded surface

extension ComposerBar {
  /// The Slack-style one-line preview. Anything that needs the full editor
  /// — focus, a pending focus request, an agent question, goal editing, an
  /// open command palette, a drag-expanded card, or a first-send editor
  /// handoff — keeps the full composer.
  var isCompact: Bool {
    isEditorFocused == false
      && !isExpanded
      && textEditorHandoffRole == .none
      && initialFocusRequest == nil
      && goalEditFocusRequest == nil
      && previewFocusRequest == nil
      && controller.activeQuestion == nil
      && !controller.isGoalEditing
      && !showsSlashCommandPopup
  }

  /// Swapped rows (goal editing, compact preview) never crossfade two
  /// texts or controls on top of each other: the outgoing row leaves at
  /// once and only the replacement fades in.
  var composerModeTransition: AnyTransition {
    .asymmetric(insertion: .opacity, removal: .identity)
  }

  var expandedSurfaceColor: Color {
    theme.isSystem ? Color(.secondarySystemGroupedBackground) : theme.composerBackground
  }

  /// One line: attach, the start of the draft, an attachment count, and
  /// the same stop/send controls as the full toolbar. Everything that isn't
  /// its own control focuses the editor.
  var compactPreviewRow: some View {
    HStack(spacing: 10) {
      attachButton
      Button(action: focusEditorFromPreview) {
        Group {
          if let preview = compactPreviewText {
            Text(preview)
              .foregroundStyle(.primary)
          } else {
            Text("Do something")
              .foregroundStyle(.tertiary)
          }
        }
        .font(.body)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaledFrame(height: ComposerCardStyle.actionDiameter, relativeTo: .body)
        .contentShape(Rectangle())
      }
      // A send from the preview launches its bubble from this line,
      // not from the folded-away editor.
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: .global)
      } action: { frame in
        onSendSourceFrameChange?(frame)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(compactPreviewText.map { "Message, \($0)" } ?? "Message")
      .accessibilityHint("Opens the composer")

      if !controller.composerAttachments.isEmpty {
        compactAttachmentCount
      }
      HStack(spacing: 6) {
        if controller.isSending {
          stopButton
          if !trimmed.isEmpty { sendButton }
        } else {
          sendButton
        }
      }
    }
  }

  /// The draft flattened onto one line; nil for an empty draft.
  var compactPreviewText: String? {
    let flattened =
      trimmed
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return flattened.isEmpty ? nil : flattened
  }

  var compactAttachmentCount: some View {
    let count = controller.composerAttachments.count
    return Button(action: focusEditorFromPreview) {
      HStack(spacing: 4) {
        Image(systemName: "paperclip")
        Text(count, format: .number)
          .monospacedDigit()
      }
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .scaledFrame(height: ComposerCardStyle.actionDiameter, relativeTo: .footnote)
      .background(Capsule().fill(Color.secondary.opacity(0.16)))
      .expandedHitTarget(base: ComposerCardStyle.actionDiameter)
    }
    .buttonStyle(.plain)
    .pointerHighlight(Capsule())
    .accessibilityLabel(count == 1 ? "1 attachment" : "\(count) attachments")
    .accessibilityHint("Opens the composer")
  }

  /// Folding and unfolding resizes the card's glass inside the session's
  /// GlassEffectContainer. Doing it in an explicit transaction lets the
  /// material morph with the content, riding alongside the keyboard's own
  /// animation instead of snapping to the new size.
  var compactMorphAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.32)
  }

  /// The request alone leaves compact mode, so the card starts unfolding
  /// on the tap rather than a frame later, when focus is reported.
  func focusEditorFromPreview() {
    withAnimation(compactMorphAnimation) {
      previewFocusRequest = UUID()
    }
  }

  /// The first report settles the initial layout without animating; later
  /// focus changes fold and unfold the card.
  func updateEditorFocus(_ isFocused: Bool) {
    guard isEditorFocused != isFocused else { return }
    if isEditorFocused == nil {
      var settle = Transaction()
      settle.disablesAnimations = true
      withTransaction(settle) { isEditorFocused = isFocused }
    } else {
      withAnimation(compactMorphAnimation) {
        isEditorFocused = isFocused
      }
    }
  }

  /// Clears whichever one-shot focus request the editor just fulfilled.
  func fulfillFocusRequest(_ request: UUID) {
    if goalEditFocusRequest == request {
      goalEditFocusRequest = nil
    } else if previewFocusRequest == request {
      previewFocusRequest = nil
    } else {
      onInitialFocusRequestFulfilled?(request)
    }
  }
}
