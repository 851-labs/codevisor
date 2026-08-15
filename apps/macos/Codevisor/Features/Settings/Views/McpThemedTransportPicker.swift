import SwiftUI
import CodevisorUI

/// The native AppKit segmented bezel doesn't consume SwiftUI theme tokens.
/// This two-choice equivalent preserves the segmented interaction model while
/// using the active palette for its surface, selection, border, and labels.
struct McpThemedTransportPicker: View {
    private struct Option: Identifiable {
        let id: String
        let label: String
    }

    @Binding var selection: String
    let theme: Theme
    @FocusState private var focusedOption: String?

    private let options = [
        Option(id: "http", label: "HTTP"),
        Option(id: "stdio", label: "STDIO"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option.id
                Button {
                    selection = option.id
                } label: {
                    Text(option.label)
                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedOption, equals: option.id)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? theme.rowSelectedBackground : Color.clear)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    }
                }
                .accessibilityLabel(option.label)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.composerBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        .onMoveCommand { direction in
            guard let currentIndex = options.firstIndex(where: { $0.id == selection }) else { return }
            let nextIndex: Int
            switch direction {
            case .left: nextIndex = max(options.startIndex, currentIndex - 1)
            case .right: nextIndex = min(options.index(before: options.endIndex), currentIndex + 1)
            default: return
            }
            selection = options[nextIndex].id
            focusedOption = selection
        }
    }
}
