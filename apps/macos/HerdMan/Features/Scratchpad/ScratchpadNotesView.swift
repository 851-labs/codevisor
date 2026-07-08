import SwiftUI
import HerdManCore

/// The Notes panel of the session inspector: free-form rich-text notes. The
/// editor is SwiftUI's native rich `TextEditor` bound to the model's
/// `AttributedString` — bold/italic/underline come from the system Format
/// menu (`TextFormattingCommands`). Bullets are literal leading characters
/// driven by `ScratchpadTextRules`: Return continues lists, `- ` / `* `
/// autoformat, and ⇧⌘7 toggles the list via the Format menu.
struct ScratchpadNotesView: View {
    @Bindable var model: ScratchpadModel
    @State private var selection = AttributedTextSelection()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $model.text, selection: $selection)
                .font(.body)
                .scrollContentBackground(.hidden)
                // TextEditor has no `prompt`; same empty-overlay pattern as
                // the composer's placeholder.
                .overlay(alignment: .topLeading) {
                    if model.text.characters.isEmpty {
                        Text("Jot down notes for this session")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            // Match the editor's internal text inset.
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 8)
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    return handleReturn()
                }
                .onChange(of: model.text) { _, newText in
                    autoformat(newText)
                }
                .focusedValue(
                    \.scratchpadFormat,
                    ScratchpadFormatActions(
                        sessionId: model.sessionId,
                        toggleBullet: {
                            apply(ScratchpadTextRules.toggleBullet(
                                text: model.text,
                                selection: selectionOffsets(in: model.text)
                            ))
                        }
                    )
                )
        }
        .onDisappear { model.flush() }
    }

    private func handleReturn() -> KeyPress.Result {
        let offsets = selectionOffsets(in: model.text)
        guard offsets.isEmpty,
              let transform = ScratchpadTextRules.continueListOnReturn(
                  text: model.text,
                  caretOffset: offsets.lowerBound
              )
        else { return .ignored }
        apply(transform)
        return .handled
    }

    /// Converts just-typed markdown shortcuts (`- `, `* `) after every edit.
    /// Applying a transform re-enters this via `onChange`, where the rule no
    /// longer matches — no recursion.
    private func autoformat(_ newText: AttributedString) {
        let offsets = selectionOffsets(in: newText)
        guard offsets.isEmpty,
              let transform = ScratchpadTextRules.applyAutoformat(
                  text: newText,
                  caretOffset: offsets.lowerBound
              )
        else { return }
        apply(transform)
    }

    private func apply(_ transform: ScratchpadTextRules.Transform) {
        model.text = transform.text
        let caret = model.text.characters.index(
            model.text.startIndex,
            offsetBy: transform.caretOffset
        )
        selection = AttributedTextSelection(insertionPoint: caret)
    }

    /// The current selection as character offsets (empty range = caret),
    /// the representation `ScratchpadTextRules` operates on.
    private func selectionOffsets(in text: AttributedString) -> Range<Int> {
        switch selection.indices(in: text) {
        case .insertionPoint(let index):
            let offset = text.characters.distance(from: text.startIndex, to: index)
            return offset ..< offset
        case .ranges(let ranges):
            guard let first = ranges.ranges.first, let last = ranges.ranges.last else {
                let end = text.characters.count
                return end ..< end
            }
            let lower = text.characters.distance(from: text.startIndex, to: first.lowerBound)
            let upper = text.characters.distance(from: text.startIndex, to: last.upperBound)
            return lower ..< upper
        @unknown default:
            let end = text.characters.count
            return end ..< end
        }
    }
}

#Preview {
    ScratchpadNotesView(
        model: ScratchpadModel(
            sessionId: UUID(),
            repository: DefaultScratchpadRepository(store: InMemoryStore())
        )
    )
    .frame(width: 300, height: 480)
}
