import CodevisorUI
import SwiftUI

struct WorkspaceInspectorCard<Content: View>: View {
  let title: String
  @Binding var isExpanded: Bool
  @ViewBuilder let content: Content
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      rows
        .fixedSize(horizontal: false, vertical: true)
        .frame(height: isExpanded ? nil : 0, alignment: .top)
        .background(Color.primary.opacity(0.034))
        .clipShape(.rect(cornerRadius: 10))
        .opacity(isExpanded ? 1 : 0)
        .padding(.top, isExpanded ? 6 : 0)
        .padding(.horizontal, 10)
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
    }
  }

  private var header: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack(spacing: 6) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .animation(Motion.indicator(reduceMotion: reduceMotion)) { chevron in
            chevron.rotationEffect(.degrees(isExpanded ? 90 : 0))
          }
          .frame(width: 16)
          .foregroundStyle(isHovered && controlActiveState == .key ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear))
      }
      .foregroundStyle(.secondary)
      .frame(height: 14)
      .padding(.leading, 20)
      .padding(.trailing, 17.5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityAddTraits(.isHeader)
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      Group(subviews: content) { subviews in
        ForEach(subviews) { subview in
          if subview.id != subviews.first?.id {
            Rectangle()
              .fill(Color.primary.opacity(0.05))
              .frame(height: 1)
              .padding(.horizontal, 10)
          }
          subview
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
      }
    }
    .labeledContentStyle(WorkspaceInspectorLabeledContentStyle())
    .labelStyle(WorkspaceInspectorLabelStyle())
  }
}

struct WorkspaceInspectorLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.icon
      configuration.title
    }
  }
}

struct WorkspaceInspectorLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline) {
      configuration.label
      Spacer(minLength: 8)
      configuration.content
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
  }
}
