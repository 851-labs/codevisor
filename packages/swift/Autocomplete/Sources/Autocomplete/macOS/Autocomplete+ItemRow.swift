#if canImport(AppKit)
  import SwiftUI

  extension Autocomplete {
    struct BottomEdge: Sendable {
      let isLast: Bool
      let height: CGFloat
      let inset: CGFloat
      let coordinateSpace: UUID
      func contains(bottom: CGFloat) -> Bool { isLast && height > 0 && abs(height - bottom - inset) <= 1 }
    }

    struct ItemRow: View {
      let item: CatalogItem
      let host: Host
      let focus: FocusState<FocusTarget?>.Binding
      let showsChecks: Bool
      let showsIcons: Bool
      let isScrolling: Bool
      let bottomEdge: BottomEdge
      @Environment(\.autocompleteStyle) private var style
      @Environment(\.isEnabled) private var isEnabled
      @State private var pointerInside = false
      @State private var rowBottom: CGFloat = 0

      private var disabled: Bool { !isEnabled || item.definition.isDisabled }
      private var hovering: Bool { pointerInside && !isScrolling }
      private var highlighted: Bool {
        !disabled && host.highlight.highlighted == item.id && (!isScrolling || host.highlight.source != .pointer)
      }
      private var foreground: Color { highlighted ? style.itemHighlight.foreground : .primary }
      private var secondaryForeground: Color { highlighted ? style.itemHighlight.foreground : .secondary }
      private var bottomRadius: CGFloat {
        bottomEdge.contains(bottom: rowBottom) ? style.metrics.bottomCornerRadius : style.metrics.itemCornerRadius
      }
      private var showsAccessories: Bool {
        !disabled && (hovering || highlighted || focus.wrappedValue?.itemID == item.id)
      }

      var body: some View {
        let metrics = style.metrics
        let edge = bottomEdge
        ZStack(alignment: .trailing) {
          Button(role: item.definition.role) {
            _ = host.activate(item.id)
          } label: {
            HStack(spacing: metrics.itemIconSpacing) {
              if showsChecks {
                Image(systemName: "checkmark")
                  .font(.system(size: metrics.checkmarkFontSize, weight: .semibold))
                  .frame(width: metrics.checkColumnWidth)
                  .opacity(item.definition.isSelected ? 1 : 0)
                  .padding(.trailing, metrics.checkColumnSpacing - metrics.itemIconSpacing)
                  .accessibilityHidden(true)
              }
              if let icon = item.definition.icon {
                icon.foregroundStyle(secondaryForeground)
                  .frame(width: metrics.itemIconSize, height: metrics.itemIconSize)
                  .accessibilityHidden(true)
              } else if showsIcons {
                Color.clear.frame(width: metrics.itemIconSize, height: metrics.itemIconSize)
              }
              if let label = item.definition.label { label } else { Text(item.definition.title).lineLimit(1) }
              Spacer(minLength: 8)
              if let shortcut = item.definition.shortcut {
                Text(Autocomplete.symbols(for: shortcut)).foregroundStyle(secondaryForeground)
                  .accessibilityHidden(true)
              }
            }
            .font(metrics.menuFont)
            .foregroundStyle(item.definition.role == .destructive && !highlighted ? .red : foreground)
            .padding(.leading, metrics.itemHorizontalInset)
            .padding(.trailing, metrics.itemHorizontalInset + accessoryWidth)
            .frame(height: metrics.itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
              if highlighted {
                HighlightBackground(
                  highlight: style.itemHighlight,
                  topCornerRadius: metrics.itemCornerRadius, bottomCornerRadius: bottomRadius)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .focusable()
          .focusEffectDisabled()
          .focused(focus, equals: .item(item.id))
          .onKeyPress(.space) { host.activate(item.id) ? .handled : .ignored }
          .accessibilityLabel(item.definition.title)
          .accessibilityAddTraits(item.definition.isSelected ? .isSelected : [])
          .accessibilityValue(item.definition.favoriteOrder == nil ? "" : Strings.text("Favorite"))
          .accessibilityHint(accessibilityHint)
          .accessibilityActions {
            ForEach(Array(item.definition.secondaryActions.enumerated()), id: \.offset) { index, action in
              Button(action.title) { _ = host.activate(item.id, secondary: index) }
            }
          }
          .contextMenu {
            ForEach(Array(item.definition.secondaryActions.enumerated()), id: \.offset) { index, action in
              Button {
                _ = host.activate(item.id, secondary: index)
              } label: {
                Label(action.title, systemImage: action.systemImage)
              }
            }
          }

          if showsAccessories {
            HStack(spacing: 0) {
              ForEach(Array(item.definition.secondaryActions.enumerated()), id: \.offset) { index, action in
                Button {
                  _ = host.activate(item.id, secondary: index)
                } label: {
                  Image(systemName: action.systemImage)
                    .font(.system(size: metrics.accessoryFontSize))
                    .frame(width: metrics.itemAccessoryWidth, height: metrics.itemHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryForeground)
                .focusable()
                .focusEffectDisabled()
                .focused(focus, equals: .secondary(item.id, index))
                .onKeyPress(.space) { host.activate(item.id, secondary: index) ? .handled : .ignored }
                .help(action.title + (action.shortcut.map { " (\(Autocomplete.symbols(for: $0)))" } ?? ""))
                .accessibilityLabel(action.title)
              }
            }
            .padding(.trailing, metrics.itemAccessoryTrailingInset)
          }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .onHover { pointerInside = $0 }
        .onChange(of: hovering) { _, hovering in
          guard !disabled else { return }
          if hovering {
            host.highlight.hover(item.id)
          } else if !isScrolling || host.highlight.source == .pointer {
            host.highlight.endHover(item.id)
          }
        }
        .background {
          if edge.isLast {
            Color.clear.onGeometryChange(for: CGFloat.self) { geometry in
              geometry.frame(in: .named(edge.coordinateSpace)).maxY
            } action: {
              rowBottom = $0
            }
          }
        }
        .help(item.definition.help ?? item.definition.title)
      }

      private var accessoryWidth: CGFloat {
        CGFloat(item.definition.secondaryActions.count) * style.metrics.itemAccessoryWidth
      }
      private var accessibilityHint: String {
        [item.definition.help, item.definition.shortcut.map(Autocomplete.accessibilityDescription)]
          .compactMap { $0 }.joined(separator: ", ")
      }
    }
  }
#endif
