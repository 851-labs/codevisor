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

  /// The find-in-chat bar, floating at the top trailing corner like a
  /// browser's.
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

  /// The live view of what this chat's agent is using: the app it controls
  /// through Computer Use or the tab it drives through Browser Use,
  /// whichever it touched last, on this Mac or the chat's host machine.
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
      // The model is adopted once: rebuild it when a tool becomes available.
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

  /// One container and namespace coordinate every Liquid Glass shape in the
  /// bottom functional layer, including the system-styled scroll button.
  var bottomChromeOverlay: some View {
    GlassEffectContainer(spacing: ComposerGlassStyle.clusterSpacing) {
      ZStack(alignment: .bottom) {
        if !isAtBottom {
          scrollToBottomButton
            .padding(.bottom, isReadOnly ? Self.composerBottomMargin : composerHeight - 10)
            .glassEffectID(
              ComposerGlassElement.scrollToBottom.rawValue,
              in: composerGlassNamespace
            )
            .glassEffectTransition(.matchedGeometry)
        }
        if !isReadOnly {
          composerOverlay
        }
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
