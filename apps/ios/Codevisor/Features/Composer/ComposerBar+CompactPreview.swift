import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Compact preview and expanded surface

/// Views that keep one visual identity while the card folds and unfolds.
enum ComposerMorphID: Hashable {
  /// The first line of text: the editor's placeholder or draft when open,
  /// the preview line when folded.
  case firstLine
}

extension ComposerBar {
  /// The Slack-style one-line preview. Anything that needs the full editor
  /// — focus, a pending focus request, an agent question, goal editing, an
  /// open command palette, a drag-expanded card, or a first-send editor
  /// handoff — keeps the full composer.
  var isCompact: Bool {
    isCompact(editorFocused: isEditorFocused)
  }

  func isCompact(editorFocused: Bool?) -> Bool {
    editorFocused == false
      && !isExpanded
      && textEditorHandoffRole == .none
      && initialFocusRequest == nil
      && goalEditFocusRequest == nil
      && previewFocusRequest == nil
      && controller.activeQuestion == nil
      && !controller.isGoalEditing
      && !showsSlashCommandPopup
  }

  /// Swapped rows (goal editing) never crossfade two controls on top of
  /// each other: the outgoing row leaves at once and only the replacement
  /// fades in.
  var composerModeTransition: AnyTransition {
    .asymmetric(insertion: .opacity, removal: .identity)
  }

  /// Folding and unfolding swap only the middle of the one bottom row —
  /// the preview line for the model and mode chips. Attach and send stay
  /// mounted, so they ride the card's resize instead of blinking.
  var compactChipsTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.animation(compactFade(delay: 0.08, duration: 0.2)),
      removal: .opacity.animation(compactFade(duration: 0.1))
    )
  }

  /// The preview line carries the draft between the row and the editor's
  /// first line (see `ComposerMorphID.firstLine`). Only one copy of the
  /// text is visible while it moves: unfolding keeps the line opaque until
  /// it reaches the editor, which fades in under it; folding shows the line
  /// at once, where the editor's text just was, and fades the editor out.
  var compactPreviewTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.animation(compactFade(duration: 0.08)),
      removal: .opacity.animation(compactFade(delay: 0.16, duration: 0.08))
    )
  }

  /// The editor side of `compactPreviewTransition`.
  var editorFadeAnimation: Animation? {
    isCompact ? compactFade(duration: 0.08) : compactFade(delay: 0.14, duration: 0.1)
  }

  func compactFade(delay: Double = 0, duration: Double) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: duration).delay(delay)
  }

  var expandedSurfaceColor: Color {
    theme.isSystem ? Color(.secondarySystemGroupedBackground) : theme.composerBackground
  }

  /// The middle of the folded row: the start of the draft (or the
  /// placeholder). It shares a matched position with the editor's first
  /// line, so folding slides the text down into the row and unfolding
  /// lifts it back up into the editor rather than swapping in place.
  var compactPreviewLine: some View {
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
      .matchedGeometryEffect(
        id: ComposerMorphID.firstLine,
        in: composerMorph,
        properties: .position,
        anchor: .leading
      )
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
  /// material morph with the content instead of snapping to the new size.
  ///
  /// Unfolding is brisk, so the editor has room by the time the keyboard
  /// settles; folding settles more softly. Neither moves the card with the
  /// keyboard — keyboard avoidance does (see `updateEditorFocus`).
  func compactMorphAnimation(unfolding: Bool) -> Animation? {
    if reduceMotion { return nil }
    return unfolding ? .snappy(duration: 0.22) : .smooth(duration: 0.32)
  }

  /// The request alone leaves compact mode, so the card starts unfolding
  /// on the tap rather than a frame later, when focus is reported.
  func focusEditorFromPreview() {
    withAnimation(compactMorphAnimation(unfolding: true)) {
      previewFocusRequest = UUID()
    }
  }

  /// The first report settles the initial layout without animating; later
  /// focus changes fold and unfold the card.
  ///
  /// A report arrives a turn after the responder change, while the keyboard
  /// is already moving, and SwiftUI applies the keyboard's safe-area change
  /// in the same update. Wrapping it in the fold animation made the whole
  /// composer follow that curve instead of the keyboard's — trailing the
  /// rising keyboard, then overshooting it. So only a report that actually
  /// folds or unfolds the card animates; a focus that a request already
  /// unfolded for (the preview tap) leaves keyboard avoidance alone.
  func updateEditorFocus(_ isFocused: Bool) {
    guard isEditorFocused != isFocused else { return }
    if isEditorFocused == nil {
      var settle = Transaction()
      settle.disablesAnimations = true
      withTransaction(settle) { isEditorFocused = isFocused }
    } else if isCompact(editorFocused: isFocused) != isCompact {
      withAnimation(compactMorphAnimation(unfolding: isFocused)) {
        isEditorFocused = isFocused
      }
    } else {
      isEditorFocused = isFocused
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
