#if canImport(AppKit)
  import SwiftUI

  public extension Autocomplete {
    /// A pinned action under the list ("Manage Harnesses…", "Add Scheme…"),
    /// separated by a divider and reachable with the keyboard as the last
    /// target. Its highlight follows the popup's bottom corners.
    struct Footer<ID: Hashable, Label: View>: View {
      let id: ID
      let help: String?
      let action: () -> Void
      let label: Label

      @Environment(\.autocompleteStyle) private var style
      @Environment(Host.self) private var host
      @Environment(Highlight<ID>.self) private var highlight

      public init(id: ID, help: String? = nil, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.id = id
        self.help = help
        self.action = action
        self.label = label()
      }

      private var isHighlighted: Bool { highlight.highlighted == id }

      public var body: some View {
        let metrics = style.metrics
        VStack(spacing: 0) {
          Divider()
          Button(action: action) {
            HStack {
              label
                .font(metrics.menuFont)
              Spacer(minLength: 8)
            }
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .padding(.horizontal, metrics.footerTitleInset)
            .frame(height: metrics.itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
              if isHighlighted {
                HighlightBackground(
                  highlight: style.itemHighlight,
                  topCornerRadius: metrics.itemCornerRadius,
                  bottomCornerRadius: metrics.bottomCornerRadius
                )
              }
            }
            .contentShape(
              UnevenRoundedRectangle(
                topLeadingRadius: metrics.itemCornerRadius,
                bottomLeadingRadius: metrics.bottomCornerRadius,
                bottomTrailingRadius: metrics.bottomCornerRadius,
                topTrailingRadius: metrics.itemCornerRadius,
                style: .continuous
              )
            )
          }
          .buttonStyle(.plain)
          .padding(.horizontal, metrics.footerHorizontalInset)
          .padding(.vertical, metrics.footerVerticalInset)
          .contentShape(Rectangle())
          .onHover { isHovering in
            guard !host.isDisabled else { return }
            if isHovering {
              highlight.hover(id)
            } else {
              highlight.endHover(id)
            }
          }
          .help(help ?? "")
        }
        .onChange(of: host.acceptTick) {
          guard host.acceptedID == AnyHashable(id) else { return }
          action()
        }
        .preference(key: TargetsKey.self, value: [Target(id: AnyHashable(id), kind: .footer)])
      }
    }
  }
#endif
