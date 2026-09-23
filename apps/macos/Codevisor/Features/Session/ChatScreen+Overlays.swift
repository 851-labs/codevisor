import SwiftUI
import CodevisorCore
import CodevisorCoreMac
import ACPKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

// MARK: - Overlays

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

  /// A live view of the window this chat's agent is controlling through
  /// Computer Use, on this Mac or the chat's host Mac.
  @ViewBuilder
  var computerUsePiPOverlay: some View {
    if let chatSessionID = controller.serverSession?.id,
      let source = computerUsePiPSource
    {
      ComputerUsePiPOverlay(
        chatSessionID: chatSessionID,
        source: source,
        isTurnRunning: controller.isSending,
        composerHeight: composerHeight
      )
      .id(chatSessionID)
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

  /// One container and namespace coordinate every Liquid Glass shape in the
  /// bottom functional layer, including the system-styled scroll button.
  var bottomChromeOverlay: some View {
    GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
      ZStack(alignment: .bottom) {
        if !isAtBottom {
          scrollToBottomButton
            .padding(.bottom, composerHeight - 10)
            .glassEffectID(
              ComposerGlassElement.scrollToBottom.rawValue,
              in: composerGlassNamespace
            )
            .glassEffectTransition(.matchedGeometry)
        }
        composerOverlay
      }
    }
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
