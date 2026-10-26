import CodevisorUI

@MainActor
final class ChromiumPageFinder: TranscriptFindTarget {
  let model = TranscriptFindModel()
  var page: () -> CVChromiumView? = { nil }

  init() {
    model.target = self
  }

  func publish(matches: Int, activeMatch: Int, finished: Bool) {
    let foundWithoutSelecting = finished && matches > 0 && activeMatch == 0
    guard !foundWithoutSelecting else {
      page()?.find(model.query, forward: true, findNext: true)
      return
    }
    model.publish(count: matches, currentNumber: matches > 0 ? activeMatch : nil)
  }

  func transcriptFindQueryDidChange(_ model: TranscriptFindModel) {
    guard let view = page(), !model.query.isEmpty else {
      page()?.stopFinding()
      model.publish(count: 0, currentNumber: nil)
      return
    }
    view.find(model.query, forward: true, findNext: false)
  }

  func transcriptFind(_ model: TranscriptFindModel, step delta: Int) {
    guard !model.query.isEmpty else { return }
    page()?.find(model.query, forward: delta > 0, findNext: true)
  }

  func transcriptFindDidDismiss(_ model: TranscriptFindModel) {
    page()?.stopFinding()
    page()?.focusPage()
  }
}
