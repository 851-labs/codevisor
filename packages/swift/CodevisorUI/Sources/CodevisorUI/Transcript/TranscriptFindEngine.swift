import Foundation
import StreamMarkdown
import TranscriptKit

@MainActor
public final class TranscriptFindEngine {
  public private(set) var query = ""
  public private(set) var results = TranscriptFindResults()
  public var onRefresh: (@MainActor () -> Void)?

  private let index = TranscriptFindIndex()
  private var generation = 0
  private var searchTask: Task<Bool, Never>?
  private var pendingStep = 0
  private var pendingRefresh: (rows: [TranscriptVirtualRow], theme: MarkdownTheme)?
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var prepareTask: Task<Void, Never>?

  public init() {}

  public var isActive: Bool { !query.isEmpty }

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

  @discardableResult
  public func step(by delta: Int) -> Bool {
    guard searchTask == nil else {
      pendingStep += delta
      return false
    }
    results.step(by: delta)
    return true
  }

  public func refresh(rows: [TranscriptVirtualRow], theme: MarkdownTheme) {
    guard isActive else { return }
    pendingRefresh = (rows, theme)
    startRefreshIfNeeded()
  }

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

  private func startRefreshIfNeeded() {
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
