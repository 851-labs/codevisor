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
        composerHeight: composerHeight,
        onOpenDesktop: openDesktopAction
      )
      .id("\(chatSessionID)/\(computerSource != nil)/\(supportsBrowser)")
    }
  }

  private var openDesktopAction: (() -> Void)? {
    guard let workspaceId = controller.hostWorkspaceId,
      let workspace = environment.workspaces.workspace(id: workspaceId),
      let desktop = MachineDesktopRegistry.shared.session(
        for: workspace, project: controller.project, environment: environment)
    else { return nil }
    return { [environment] in
      Task {
        guard await desktop.register() else { return }
        MachineDesktopWindows.shared.present(desktop, machineId: workspace.serverId, environment: environment)
      }
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

  var transcriptBottomFade: TranscriptBottomFade {
    guard !isReadOnly, !usesSlimComposer, composerCardHeight > 0 else { return .none }
    let cardHeight = composerCardHeight
    let fadeStart = cardHeight * 0.15
    let fadeEnd = max(cardHeight / 2, cardHeight - composerCardStyle.cornerRadius)
    return TranscriptBottomFade(
      clearHeight: cardHeight - fadeEnd + Self.composerBottomMargin,
      fadeHeight: fadeEnd - fadeStart
    )
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
