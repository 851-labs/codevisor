import CodevisorCore
import CodevisorUI
import SwiftUI

enum ComposerMorphID: Hashable {
  case firstLine
}

extension ComposerBar {
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

  var composerModeTransition: AnyTransition {
    .asymmetric(insertion: .opacity, removal: .identity)
  }

  var compactChipsTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.animation(compactFade(delay: 0.08, duration: 0.2)),
      removal: .opacity.animation(compactFade(duration: 0.1))
    )
  }

  var compactPreviewTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.animation(compactFade(duration: 0.08)),
      removal: .opacity.animation(compactFade(delay: 0.16, duration: 0.08))
    )
  }

  var editorFadeAnimation: Animation? {
    isCompact ? compactFade(duration: 0.08) : compactFade(delay: 0.14, duration: 0.1)
  }

  func compactFade(delay: Double = 0, duration: Double) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: duration).delay(delay)
  }

  var expandedSurfaceColor: Color {
    theme.isSystem ? Color(.secondarySystemGroupedBackground) : theme.composerBackground
  }

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
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .global)
    } action: { frame in
      onSendSourceFrameChange?(frame)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(compactPreviewText.map { "Message, \($0)" } ?? "Message")
    .accessibilityHint("Opens the composer")
  }

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

  func compactMorphAnimation(unfolding: Bool) -> Animation? {
    if reduceMotion { return nil }
    return unfolding ? .snappy(duration: 0.22) : .smooth(duration: 0.32)
  }

  func focusEditorFromPreview() {
    withAnimation(compactMorphAnimation(unfolding: true)) {
      previewFocusRequest = UUID()
    }
  }

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
