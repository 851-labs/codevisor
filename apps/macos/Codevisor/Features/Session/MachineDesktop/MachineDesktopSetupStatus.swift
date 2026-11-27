import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopSetupStatus: View {
  enum Size { case card, pane }

  let store: StoreOf<MachineDesktopSetup>
  let view: UUID
  let size: Size
  let onOpenTerminal: (() -> Void)?

  var body: some View {
    VStack(spacing: size == .pane ? 12 : 8) {
      switch store.phase {
      case .asking: notice("questionmark.circle", MachineDesktopWords.waitingForAnswer(on: store.machineName), nil)
      case .checking: progress(MachineDesktopWords.checking(store.machineName))
      case .ready: progress(MachineDesktopWords.starting)
      case .settingUp(let line): progress(line)
      case .noDesktop(let setUpBefore): noDesktop(setUpBefore)
      case .needsAdministrator(let sentence): administratorNeeded(sentence)
      case .failed(let sentence): failed(sentence)
      case .updateNeeded:
        notice("arrow.down.circle", MachineDesktopWords.updateNeeded(on: store.machineName), nil)
      }
    }
    .padding(size == .pane ? 24 : 16)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("machineDesktop.setup")
  }

  private func act(_ action: MachineDesktopSetup.Action) {
    store.send(.interacted(from: view))
    store.send(action)
  }

  private func failed(_ sentence: String) -> some View {
    notice(
      "display.trianglebadge.exclamationmark", sentence,
      .init(title: "Try Again") { act(.tryAgainButtonTapped) })
  }

  private func noDesktop(_ setUpBefore: Bool) -> some View {
    notice(
      "display", setUpBefore ? MachineDesktopWords.setUpBefore : MachineDesktopWords.noDesktop,
      .init(title: setUpBefore ? "Set Up Again" : "Set Up a Desktop") { act(.setUpButtonTapped) })
  }

  @ViewBuilder
  private func administratorNeeded(_ sentence: String) -> some View {
    if let onOpenTerminal {
      notice("lock", sentence, .init(title: "Open Terminal", action: onOpenTerminal))
    } else {
      notice("lock", "\(sentence) \(MachineDesktopWords.runInATerminal(store.terminalCommand))", nil)
    }
  }

  private func notice(
    _ symbol: String, _ sentence: String, _ offer: MachineDesktopSetupNotice.Offer?
  ) -> some View {
    MachineDesktopSetupNotice(symbol: symbol, sentence: sentence, offer: offer, size: size)
  }

  @ViewBuilder
  private func progress(_ line: String) -> some View {
    ProgressView().controlSize(.small)
    Text(line)
      .font(size == .pane ? .body : .callout)
      .foregroundStyle(size == .pane ? .primary : .secondary)
      .multilineTextAlignment(.center)
      .contentTransition(.opacity)
  }
}
