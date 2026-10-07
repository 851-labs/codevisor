#if os(macOS)
  import AppKit
  import SwiftUI

  /// The floating find-in-chat bar: a query field, "3 of 12", previous and
  /// next, and close. Keys follow Chrome's find bar: Return steps to the next
  /// match and Shift-Return to the previous one (both repeat while held), and
  /// Escape closes.
  public struct TranscriptFindBar: View {
    private let model: TranscriptFindModel
    @FocusState private var isFocused: Bool

    public init(model: TranscriptFindModel) {
      self.model = model
    }

    public var body: some View {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        queryField
        if let status = model.status {
          Text(status)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(status == "No results" ? status : "Match \(status)")
        }
        HStack(spacing: 0) {
          stepButton("chevron.up", label: "Previous match", help: "Previous match (⇧↩)") {
            model.findPrevious()
          }
          stepButton("chevron.down", label: "Next match", help: "Next match (↩)") {
            model.findNext()
          }
        }
        .disabled(model.matchCount == 0)
        Button {
          model.dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 26, height: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close (esc)")
        .accessibilityLabel("Close find")
      }
      .padding(.leading, 12)
      .padding(.trailing, 4)
      .frame(height: 36)
      .glassEffect(.regular, in: .capsule)
      .onChange(of: model.focusRequest, initial: true) {
        Task { @MainActor in
          await Task.yield()
          isFocused = true
          await Task.yield()
          // A repeat ⌘F selects the existing query so typing replaces it.
          if !model.query.isEmpty {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
          }
        }
      }
    }

    private var queryField: some View {
      TextField(
        "Find in chat",
        text: Binding(get: { model.query }, set: { model.updateQuery($0) })
      )
      .textFieldStyle(.plain)
      .autocorrectionDisabled()
      .focused($isFocused)
      .accessibilityLabel("Find in chat")
      // Handled here rather than in `onSubmit` so Shift-Return can step back
      // and a held key keeps stepping, as in Chrome.
      .onKeyPress(.return, phases: [.down, .repeat]) { press in
        if press.modifiers.contains(.shift) {
          model.findPrevious()
        } else {
          model.findNext()
        }
        return .handled
      }
      .onExitCommand { model.dismiss() }
    }

    private func stepButton(
      _ systemImage: String,
      label: String,
      help: String,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        Image(systemName: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 26, height: 26)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .help(help)
      .accessibilityLabel(label)
    }
  }
#endif
