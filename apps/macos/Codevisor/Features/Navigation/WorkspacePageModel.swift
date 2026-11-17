import Foundation
import Observation

@Observable
final class WorkspacePageModel {
  private(set) var chrome: WorkspaceChrome?
  @ObservationIgnored private var chromePublisher: UUID?

  func publish(_ chrome: WorkspaceChrome, from publisher: UUID) {
    chromePublisher = publisher
    self.chrome = chrome
  }

  func withdrawChrome(from publisher: UUID) {
    guard chromePublisher == publisher else { return }

    chromePublisher = nil
    chrome = nil
  }
}
