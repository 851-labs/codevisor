import AppKit
import SwiftUI
import CodevisorUI

struct McpScrollingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEditable: Bool
    let isSelected: Bool
    let theme: Theme
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        // HIG: match standard controls via the dynamic system font variant
        // rather than a hardcoded size.
        textField.font = .controlContentFont(ofSize: NSFont.systemFontSize)
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.lineBreakMode = .byClipping
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        textField.isEditable = isEditable
        textField.isSelectable = isEditable
        if theme.isSystem {
            textField.placeholderString = placeholder
            textField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        } else {
            textField.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: NSColor(theme.textTertiary)]
            )
            textField.textColor = NSColor(theme.textPrimary)
        }
        if textField.currentEditor() == nil, textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: McpScrollingTextField

        init(_ parent: McpScrollingTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }
    }
}
