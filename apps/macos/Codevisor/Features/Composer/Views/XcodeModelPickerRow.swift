import AppKit
import SwiftUI

struct XcodeModelPickerRow: View {
    let title: String
    let isSelected: Bool
    let isKeyboardHighlighted: Bool
    let isDisabled: Bool
    let favoriteAction: ModelPickerFavoriteAction
    let onHover: (Bool) -> Void
    let onFavoriteAction: () -> Void
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(XcodeModelPickerMetrics.menuFont)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .foregroundStyle(isKeyboardHighlighted ? Color.white : Color.primary)
                .padding(.leading, XcodeModelPickerMetrics.rowHorizontalInset)
                .padding(
                    .trailing,
                    XcodeModelPickerMetrics.rowHorizontalInset
                        + XcodeModelPickerMetrics.rowFavoriteActionWidth
                )
                .frame(height: XcodeModelPickerMetrics.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isKeyboardHighlighted {
                        XcodeMenuSelectionBackground()
                    }
                }
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: XcodeModelPickerMetrics.rowCornerRadius,
                        style: .continuous
                    )
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: favoriteAction.label) {
                onFavoriteAction()
            }

            if isHovering, !isDisabled {
                Button(action: onFavoriteAction) {
                    Image(systemName: favoriteAction.symbolName)
                        .font(.system(size: 11, weight: .regular))
                        .frame(
                            width: XcodeModelPickerMetrics.rowFavoriteActionWidth,
                            height: XcodeModelPickerMetrics.rowHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isKeyboardHighlighted ? Color.white : Color.secondary)
                .padding(.trailing, XcodeModelPickerMetrics.rowFavoriteActionTrailingInset)
                .help(favoriteAction.label)
            }
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .onHover { isHovering in
            self.isHovering = isHovering
            onHover(isHovering)
        }
    }
}

struct ModelPickerFooterRow: View {
    let title: String
    let isKeyboardHighlighted: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(XcodeModelPickerMetrics.menuFont)
                Spacer(minLength: 8)
            }
            .foregroundStyle(isKeyboardHighlighted ? Color.white : Color.primary)
            .padding(.horizontal, XcodeModelPickerMetrics.footerTitleInset)
            .frame(height: XcodeModelPickerMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isKeyboardHighlighted {
                    XcodeMenuSelectionBackground(
                        bottomCornerRadius: XcodeModelPickerMetrics.footerBottomCornerRadius
                    )
                }
            }
            .contentShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: XcodeModelPickerMetrics.rowCornerRadius,
                    bottomLeadingRadius: XcodeModelPickerMetrics.footerBottomCornerRadius,
                    bottomTrailingRadius: XcodeModelPickerMetrics.footerBottomCornerRadius,
                    topTrailingRadius: XcodeModelPickerMetrics.rowCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, XcodeModelPickerMetrics.footerHorizontalInset)
        .padding(.vertical, XcodeModelPickerMetrics.footerVerticalInset)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .help("Open Harness Settings")
    }
}

private struct XcodeMenuSelectionBackground: View {
    var bottomCornerRadius = XcodeModelPickerMetrics.rowCornerRadius

    var body: some View {
        NativeMenuSelectionMaterial()
            // AppKit applies this small color transform when `.selection` is
            // hosted by an NSMenu. Reproduce it in the SwiftUI popover while
            // retaining the system material's accent and appearance behavior.
            .brightness(0.0274)
            .saturation(1.0126)
            .hueRotation(.degrees(-1.30))
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: XcodeModelPickerMetrics.rowCornerRadius,
                    bottomLeadingRadius: bottomCornerRadius,
                    bottomTrailingRadius: bottomCornerRadius,
                    topTrailingRadius: XcodeModelPickerMetrics.rowCornerRadius,
                    style: .continuous
                )
            )
    }
}

private struct NativeMenuSelectionMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        view.setAccessibilityElement(false)
    }
}
