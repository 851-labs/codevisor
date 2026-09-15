import CodevisorUI
import SwiftUI

struct ComposerSlashCommandPopup: View {
  private var cardStyle = ComposerCardStyle()
  @Environment(\.theme) private var theme

  private static let listInset: CGFloat = 6

  private var selectionShape: ConcentricRectangle {
    cardStyle.insetShape(by: Self.listInset)
  }

  let isLoading: Bool
  let matches: [ComposerSlashItem]
  let selectedIndex: Int
  let height: CGFloat
  let onContentHeightChange: (CGFloat) -> Void
  let onSelect: (ComposerSlashItem) -> Void

  @ViewBuilder
  var body: some View {
    if isLoading {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Connecting to harness…")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        onContentHeightChange($0)
      }
      .background(theme.windowBackground, in: cardStyle.shape)
      .composerGlassSurface(shape: cardStyle.shape)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Connecting to harness")
    } else if !matches.isEmpty {
      commandList
    }
  }

  private var commandList: some View {
    let selectedIndex = min(selectedIndex, matches.count - 1)
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
            commandRow(command, isSelected: index == selectedIndex)
              .id(command.id)
          }
        }
        .padding(Self.listInset)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          onContentHeightChange($0)
        }
      }
      .frame(height: height)
      .onChange(of: selectedIndex) { _, index in
        guard matches.indices.contains(index) else { return }
        proxy.scrollTo(matches[index].id)
      }
    }
    .clipShape(cardStyle.shape)
    // The palette overlays other glass accessories, whose text must not
    // show through this surface when their materials merge.
    .background(theme.windowBackground, in: cardStyle.shape)
    .composerGlassSurface(shape: cardStyle.shape)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Slash commands")
    .accessibilityHint(
      "Use the up and down arrows to choose a command, Return to accept, Escape to close"
    )
  }

  private func commandRow(_ command: ComposerSlashItem, isSelected: Bool) -> some View {
    Button {
      onSelect(command)
    } label: {
      HStack(spacing: 10) {
        Text("/\(command.name)")
          .fontWeight(.medium)
        Text(command.description)
          .lineLimit(1)
          .foregroundStyle(
            isSelected
              ? AnyShapeStyle(.white.opacity(0.85))
              : AnyShapeStyle(.secondary)
          )
        Spacer(minLength: 0)
        if let hint = command.hint {
          Text(hint)
            .lineLimit(1)
            .foregroundStyle(
              isSelected
                ? AnyShapeStyle(.white.opacity(0.7))
                : AnyShapeStyle(.tertiary)
            )
        }
      }
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        selectionShape
          .fill(isSelected ? theme.accent : .clear)
      )
      .contentShape(selectionShape)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("/\(command.name), \(command.description)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
