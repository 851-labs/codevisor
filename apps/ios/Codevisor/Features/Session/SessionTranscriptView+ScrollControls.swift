import CodevisorCore
import CodevisorUI
import SwiftUI
import TranscriptKit

extension SessionTranscriptView {
  var visibleEarlierHistoryCollapse: TranscriptEarlierHistoryCollapse? {
    composerExpanded ? nil : earlierHistoryCollapse
  }

  var scrollToBottomButton: some View {
    Button {
      followsLatest = true
      scrollCommand.token &+= 1
    } label: {
      Image(systemName: "arrow.down")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .accessibilityLabel("Scroll to bottom")
  }

  func collapseStepsButton(_ collapse: TranscriptEarlierHistoryCollapse) -> some View {
    Button {
      collapse {
        disclosure.setExpanded(
          collapse.section.kind.earlierHistoryDisclosureKey(messageID: collapse.section.messageID),
          false
        )
      }
    } label: {
      Label {
        Text("Collapse steps")
          .font(.system(size: 13, weight: .medium))
      } icon: {
        Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
          .font(.system(size: 13, weight: .semibold))
      }
      .foregroundStyle(.secondary)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.capsule)
    .controlSize(.large)
  }

  var transcriptScrollControls: some View {
    HStack(spacing: ComposerGlassStyle.clusterSpacing) {
      if let collapse = visibleEarlierHistoryCollapse {
        collapseStepsButton(collapse)
          .glassEffectID(
            ComposerGlassElement.collapseSteps.rawValue,
            in: composerGlassNamespace
          )
          .glassEffectTransition(.matchedGeometry)
      }
      if showsScrollToBottom {
        scrollToBottomButton
          .glassEffectID(
            ComposerGlassElement.scrollToBottom.rawValue,
            in: composerGlassNamespace
          )
          .glassEffectTransition(.materialize)
          .transition(.opacity)
      }
    }
  }
}
