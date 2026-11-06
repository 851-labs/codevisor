import CodevisorCore
import CodevisorUI
import SimulatorPane

enum PaneToolbarSource {
  case browser(ChromiumBrowserModel)
  case screenSharing(ScreenSharingPane)
  case file(FilePaneModel)
  case review(ReviewPaneModel)
  case simulator(SimulatorPaneModel)

  private static let kinds: Set<PaneKind> = [.browser, .screenSharing, .document, .review, .simulator]

  init?(group: PaneGroupModel) {
    guard let kind = group.state.selectedPane?.kind, Self.kinds.contains(kind) else { return nil }

    switch group.selectedPane {
    case let browser as BrowserPane: self = .browser(browser.model)
    case let sharing as ScreenSharingPane where sharing.store != nil: self = .screenSharing(sharing)
    case let file as FilePane: self = .file(file.model)
    case let review as ReviewPane: self = .review(review.model)
    case let simulator as AppleSimulatorPane:
      guard let model = simulator.model else { return nil }
      self = .simulator(model)
    default: return nil
    }
  }

  var browser: ChromiumBrowserModel? {
    guard case let .browser(model) = self else { return nil }
    return model
  }

  var screenSharing: ScreenSharingPane? {
    guard case let .screenSharing(pane) = self else { return nil }
    return pane
  }

  var file: FilePaneModel? {
    guard case let .file(model) = self else { return nil }
    return model
  }

  var review: ReviewPaneModel? {
    guard case let .review(model) = self else { return nil }
    return model
  }

  var simulator: SimulatorPaneModel? {
    guard case let .simulator(model) = self else { return nil }
    return model
  }

  var hasLeadingControls: Bool {
    switch self {
    case .browser, .screenSharing, .simulator: true
    case .file, .review: false
    }
  }

  var hasTrailingControls: Bool {
    switch self {
    case let .file(model): FilePanePreviewToggle.isShown(for: model)
    case .screenSharing, .review, .simulator: true
    case .browser: false
    }
  }

  var replacesTitle: Bool {
    switch self {
    case .browser: true
    case let .simulator(model): model.device != nil
    case .screenSharing, .file, .review: false
    }
  }
}
