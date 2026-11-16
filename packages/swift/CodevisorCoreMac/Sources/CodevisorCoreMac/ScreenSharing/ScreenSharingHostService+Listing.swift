import CodevisorClient
import Foundation

extension ScreenSharingHostService {
  func listed(_ available: [Display]) -> [Display] {
    logicalDisplays.list(available, shared: current.map(shared))
  }

  func describe(_ session: ScreenSharingHostSession, among available: [Display]) {
    let listed = logicalDisplays.list(available, shared: shared(session))
    let own = listed.first { $0.id == session.captureDisplayID } ?? listed.first { $0.id == session.displayID }
    guard let own else { return }

    session.displays = listed.map(\.description)
    session.display = own.description
    if logicalDisplays.kind(own.id) != .hostVirtual { session.sharesStandIn = logicalDisplays.kind(own.id) == .standIn }
    displayChoice.remember(own.description, for: session.owner)
  }

  func refreshDisplays(of session: ScreenSharingHostSession) async {
    guard let available = try? await enumerateDisplays(), current === session,
      !session.stopping, session.displaySwitch?.isMoving != true
    else { return }

    describe(session, among: available)
  }

  func shared(_ session: ScreenSharingHostSession) -> ScreenSharingHostLogicalDisplays.Shared {
    .init(description: session.display, capturing: session.captureDisplayID, isStandIn: session.sharesStandIn)
  }
}
