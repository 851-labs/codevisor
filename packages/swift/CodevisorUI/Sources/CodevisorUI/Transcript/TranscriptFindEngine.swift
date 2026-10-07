import Foundation
import StreamMarkdown
import TranscriptKit

/// Searches a transcript's rows for the find bar.
///
/// Only final response Markdown is searched (see `findableBlocks`). Counting
/// runs on a background index, so unmounted rows still contribute matches
/// without the main thread rendering or scanning a long transcript; this
/// type keeps the published results and the current match on the main
/// actor. A mounted row re-derives exact ranges from the text its surfaces
/// actually display.
@MainActor
public final class TranscriptFindEngine {
  public private(set) var query = ""
  public private(set) var results = TranscriptFindResults()
  /// Called when a background re-count (streaming, pagination) changes the
  /// results, so the host can republish and repaint without moving the
  /// viewport.
  public var onRefresh: (@MainActor () -> Void)?

  private let index = TranscriptFindIndex()
  /// Bumped by every new query; work started for an older one is dropped.
  private var generation = 0
  private var searchTask: Task<Bool, Never>?
  /// Steps taken while a search is in flight, applied to its results.
  private var pendingStep = 0
  private var pendingRefresh: (rows: [TranscriptVirtualRow], theme: MarkdownTheme)?
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var prepareTask: Task<Void, Never>?

  public init() {}

  public var isActive: Bool { !query.isEmpty }

  /// Starts a new search. The current match will be the first at or below
  /// `rows[firstVisibleRow]`. The returned task yields true once the results
  /// are published, or false when a newer query superseded this one.
  @discardableResult
  public func search(
    _ query: String,
    rows: [TranscriptVirtualRow],
    firstVisibleRow: Int,
    theme: MarkdownTheme
  ) -> Task<Bool, Never> {
    generation &+= 1
    let generation = generation
    searchTask?.cancel()
    cancelRefresh()
    pendingStep = 0
    self.query = query
    guard !query.isEmpty else {
      results = TranscriptFindResults()
      searchTask = nil
      return Task { true }
    }
    let index = index
    // Text already being built since the bar opened is reused, not redone.
    let preparing = prepareTask
    let task = Task { [weak self] () -> Bool in
      await preparing?.value
      let counts = try? await index.counts(of: query, in: rows, theme: theme)
      guard let self, self.generation == generation, let counts else { return false }
      let startingRow = counts.firstIndex { $0.rowIndex >= firstVisibleRow } ?? counts.count
      results = TranscriptFindResults(rows: counts.map(\.count), startingRow: startingRow)
      if pendingStep != 0 {
        results.step(by: pendingStep)
        pendingStep = 0
      }
      searchTask = nil
      startRefreshIfNeeded()
      return true
    }
    searchTask = task
    return task
  }

  /// Moves to the next or previous match. Returns false when a search is
  /// still running; the step is applied to its results instead.
  @discardableResult
  public func step(by delta: Int) -> Bool {
    guard searchTask == nil else {
      pendingStep += delta
      return false
    }
    results.step(by: delta)
    return true
  }

  /// Re-counts after the rows changed. At most one re-count runs at a time;
  /// rows that change while it runs are counted once it finishes.
  public func refresh(rows: [TranscriptVirtualRow], theme: MarkdownTheme) {
    guard isActive else { return }
    pendingRefresh = (rows, theme)
    startRefreshIfNeeded()
  }

  /// Builds the transcript's text in the background while the bar is open
  /// but empty, so the first keystroke only has to scan.
  /// A search awaits this rather than rendering the same text again.
  public func prepare(rows: [TranscriptVirtualRow], theme: MarkdownTheme) {
    guard !isActive else { return }
    let index = index
    let previous = prepareTask
    prepareTask = Task(priority: .utility) {
      await previous?.value
      _ = try? await index.counts(of: "", in: rows, theme: theme)
    }
  }

  public func clear() {
    generation &+= 1
    searchTask?.cancel()
    searchTask = nil
    cancelRefresh()
    prepareTask?.cancel()
    prepareTask = nil
    pendingStep = 0
    query = ""
    results = TranscriptFindResults()
    let index = index
    Task { await index.reset() }
  }

  /// The highlights for each of a mounted row's surfaces, given the text
  /// those surfaces display. Matches are numbered through the surfaces in
  /// order, which is how `TranscriptFindMatch.ordinal` counts them. Bounded
  /// by the mounted window, so it stays on the main actor with the views.
  public func highlights(
    forRow rowKey: String,
    surfaceTexts: [String]
  ) -> [TranscriptFindHighlights?] {
    guard isActive else { return surfaceTexts.map { _ in nil } }
    let current = results.currentOrdinal(inRow: rowKey)
    var ordinal = 0
    return surfaceTexts.map { text in
      let ranges = TranscriptFindText.ranges(of: query, in: text)
      defer { ordinal += ranges.count }
      guard !ranges.isEmpty else { return nil }
      let currentIndex = current.flatMap { current in
        (ordinal..<ordinal + ranges.count).contains(current) ? current - ordinal : nil
      }
      return TranscriptFindHighlights(ranges: ranges, currentIndex: currentIndex)
    }
  }

  // MARK: Refresh

  private func startRefreshIfNeeded() {
    // A search in flight re-counts everything; its completion picks up
    // whatever rows arrived meanwhile.
    guard searchTask == nil, refreshTask == nil, pendingRefresh != nil else { return }
    refreshGeneration &+= 1
    let refreshGeneration = refreshGeneration
    let index = index
    refreshTask = Task { [weak self] in
      while let self, let (rows, theme) = pendingRefresh {
        pendingRefresh = nil
        let generation = generation
        let counts = try? await index.counts(of: query, in: rows, theme: theme)
        guard self.generation == generation, let counts else { break }
        results.update(rows: counts.map(\.count))
        onRefresh?()
      }
      if let self, self.refreshGeneration == refreshGeneration {
        refreshTask = nil
      }
    }
  }

  private func cancelRefresh() {
    refreshTask?.cancel()
    refreshTask = nil
    pendingRefresh = nil
  }
}
