import SwiftUI
import CodevisorCore
import CodevisorCoreMac
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

extension ChatScreen {
  @ViewBuilder
  var initialLoadingOverlay: some View {
    if showsInitialLoadingSpinner, !isInitialTranscriptReady {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
  }

  @ViewBuilder
  var findBarOverlay: some View {
    let model = presentationSurface.findModel
    if model.isPresented {
      TranscriptFindBar(model: model)
        .frame(width: 340)
        .padding(.top, 12)
        .padding(.trailing, 16)
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
  }

  @ViewBuilder
  var livePreviewPiPOverlay: some View {
    let serverId = controller.project.serverId
    let supportsBrowser = environment.machines.statusByMachineId[serverId]?.supportsLivePreview == true
    let computerSource = computerUsePiPSource
    if let chatSessionID = controller.serverSession?.id, computerSource != nil || supportsBrowser {
      ComputerUsePiPOverlay(
        model: AgentLivePreviewPiPModel(
          computer: computerSource.map { ComputerUsePiPModel(chatSessionID: chatSessionID, source: $0) },
          browser: supportsBrowser
            ? BrowserUsePiPModel(chatSessionID: chatSessionID, client: environment.machines.client(for: serverId))
            : nil),
        isTurnRunning: controller.isSending,
        composerHeight: composerHeight
      )
      .id("\(chatSessionID)/\(computerSource != nil)/\(supportsBrowser)")
    }
  }

  private var computerUsePiPSource: ComputerUsePiPModel.Source? {
    let serverId = controller.project.serverId
    if codevisorMachineIsThisMac(serverId, statusByMachineId: environment.machines.statusByMachineId) {
      return .local
    }
    guard let computerUsePiPPane,
      environment.machines.statusByMachineId[serverId]?.supportsComputerUseStreaming == true
    else { return nil }
    return .remote(client: environment.machines.client(for: serverId), pane: computerUsePiPPane)
  }

  @ViewBuilder
  var composerScrim: some View {
    if !isReadOnly, composerCardHeight > 0 {
      let cardHeight = composerCardHeight
      let height = cardHeight + Self.composerBottomMargin
      let solidStart = cardHeight * 0.15
      let solidEnd = max(cardHeight / 2, cardHeight - composerCardStyle.cornerRadius)
      let blurPeak = min(cardHeight * 0.45, solidEnd)
      let blurFadeStart = max(blurPeak, solidStart + (solidEnd - solidStart) * 0.7)
      ZStack(alignment: .top) {
        Rectangle()
          .fill(.ultraThinMaterial)
          .mask(
            Self.scrimRamp(
              rising: 0...blurPeak / cardHeight,
              falling: blurFadeStart / cardHeight...solidEnd / cardHeight
            )
          )
          .frame(height: cardHeight)
          .clipShape(composerCardStyle.shape)
        ZStack(alignment: .top) {
          Rectangle()
            .fill(.background)
            .frame(height: cardHeight)
            .clipShape(composerCardStyle.shape)
          Rectangle()
            .fill(.background)
            .padding(.top, cardHeight / 2)
        }
        .mask(Self.scrimRamp(rising: solidStart / height...solidEnd / height))
      }
      .frame(height: height)
      .padding(.horizontal, Self.composerHorizontalPadding)
      .frame(maxWidth: Self.composerMaxWidth)
      .frame(maxWidth: .infinity)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .animation(Motion.quick(reduceMotion: reduceMotion), value: composerCardHeight)
    }
  }

  static func scrimRamp(
    rising: ClosedRange<CGFloat>,
    falling: ClosedRange<CGFloat>? = nil
  ) -> LinearGradient {
    func easedStops(across range: ClosedRange<CGFloat>, rising: Bool) -> [Gradient.Stop] {
      let steps = 8
      return (0...steps).map { step in
        let progress = CGFloat(step) / CGFloat(steps)
        let eased = progress * progress * (3 - 2 * progress)
        return Gradient.Stop(
          color: .black.opacity(rising ? eased : 1 - eased),
          location: range.lowerBound + (range.upperBound - range.lowerBound) * progress
        )
      }
    }
    let stops = easedStops(across: rising, rising: true) + (falling.map { easedStops(across: $0, rising: false) } ?? [])
    return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
  }

  var bottomChromeOverlay: some View {
    GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
      ZStack(alignment: .bottom) {
        if !isAtBottom || earlierHistoryCollapse != nil {
          HStack(spacing: ComposerGlassStyle.clusterSpacing) {
            if let earlierHistoryCollapse {
              collapseStepsButton(earlierHistoryCollapse)
                .glassEffectID(
                  ComposerGlassElement.collapseSteps.rawValue,
                  in: composerGlassNamespace
                )
                .glassEffectTransition(.matchedGeometry)
            }
            if !isAtBottom {
              scrollToBottomButton
                .glassEffectID(
                  ComposerGlassElement.scrollToBottom.rawValue,
                  in: composerGlassNamespace
                )
                .glassEffectTransition(.matchedGeometry)
            }
          }
          .padding(.bottom, isReadOnly ? Self.composerBottomMargin : composerHeight - 10)
        }
        if !isReadOnly {
          composerOverlay
        }
      }
    }
  }

  func collapseStepsButton(_ collapse: TranscriptEarlierHistoryCollapse) -> some View {
    Button {
      collapse {
        controller.disclosure.setExpanded(
          collapse.section.kind.earlierHistoryDisclosureKey(messageID: collapse.section.messageID),
          false
        )
      }
    } label: {
      Label {
        Text("Collapse steps")
          .font(.system(size: 12, weight: .medium))
      } icon: {
        Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
          .font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(.secondary)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.capsule)
    .controlSize(.large)
    .help("Collapse earlier steps")
  }

  var scrollToBottomButton: some View {
    Button {
      autoFollow = true
      scrollCommand.token &+= 1
    } label: {
      Image(systemName: "arrow.down")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.glass)
    .buttonBorderShape(.circle)
    .controlSize(.large)
    .help("Scroll to bottom")
    .accessibilityLabel("Scroll to bottom")
  }
}
