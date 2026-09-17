import Foundation

extension SessionModel {
  /// The visible history is a window, independent of the latest live turn.
  /// Moving either way reloads permanent rows using their stable sequence.
  func boundHistoryWindow(keepingOldest: Bool) {
    if settledConversation.count > 64 {
      if keepingOldest {
        settledConversation = Array(settledConversation.prefix(64))
        hasNewerHistory = true
      } else {
        settledConversation = Array(settledConversation.suffix(64))
        hasOlderHistory = true
        if let first = settledConversation.first {
          olderHistoryCursor = transcriptSequences[first.id].map(String.init) ?? "before-id:\(first.id.uuidString)"
        }
      }
      rebuildSettledIndex()
    }
    let resident = Set(conversation.map(\.id))
    transcriptSequences = transcriptSequences.filter { resident.contains($0.key) }
    toolOwnerItemIds = toolOwnerItemIds.filter { resident.contains($0.value) }
  }

  @discardableResult
  public func loadNewerHistory(latest: Bool = false) async -> Int {
    guard hasNewerHistory, !isLoadingNewerHistory, !isLoadingOlderHistory,
      let last = settledConversation.last
    else { return 0 }
    isLoadingNewerHistory = true
    defer { isLoadingNewerHistory = false }
    do {
      let previousResidentIDs = Set(conversation.map(\.id))
      let cursor = transcriptSequences[last.id].map { "after:\($0)" } ?? "after-id:\(last.id.uuidString)"
      let page = try await transport.transcriptPage(before: latest ? nil : cursor, limit: Self.olderTranscriptPageSize)
      try Task.checkCancellation()
      let existing = Dictionary(uniqueKeysWithValues: conversation.map { ($0.id, $0) })
      let added: [ConversationItem]
      if latest {
        // Jump directly to the latest window. Keep live versions of overlapping
        // items: the snapshot may have been taken before a streaming update.
        added = page.conversation.filter { $0.id != activeItem?.id }.map { existing[$0.id] ?? $0 }
        let pageIDs = Set(page.conversation.map(\.id))
        let arrivedDuringFetch = settledConversation.filter {
          !previousResidentIDs.contains($0.id) && !pageIDs.contains($0.id)
        }
        settledConversation = added + arrivedDuringFetch
        olderHistoryCursor = page.nextBefore
        hasOlderHistory = page.hasMore
      } else {
        added = page.conversation.filter { existing[$0.id] == nil }
        settledConversation.append(contentsOf: added)
      }
      transcriptSequences.merge(page.sequences) { _, new in new }
      hasNewerHistory = page.hasNewer
      boundHistoryWindow(keepingOldest: false)
      rebuildSettledIndex()
      return added.count
    } catch {
      if !isTaskCancellation(error) { errorMessage = serverErrorMessage(error) }
      return 0
    }
  }

  /// Detailed pages have a separate small LRU. Eviction restores the summary,
  /// and the disclosure can fetch its permanent details again at any time.
  func retainDetailWindow(itemId: String) {
    residentDetailItemIds.removeAll { $0 == itemId }
    residentDetailItemIds.append(itemId)
    while residentDetailItemIds.count > 8 {
      let evicted = residentDetailItemIds.removeFirst()
      transcriptDetailsCache.removeValue(forKey: evicted)
      transcriptDetailWindows.removeValue(forKey: evicted)
      guard
        let index = settledConversation.firstIndex(where: { $0.id.uuidString.lowercased() == evicted.lowercased() }),
        case .assistant(var message) = settledConversation[index]
      else { continue }
      let answer = message.turn.finalText
      message.turn.entries = [answer].compactMap { $0 }
      message.turn.subagents = [:]
      message.turn.hasHydratedWorkedDetails = false
      message.turn.hasDeferredWorkedDetails = true
      message.turn.deferredDetailItemId = evicted
      message.turn.detailNextAfter = nil
      message.turn.detailPreviousBefore = nil
      message.turn.pruneEntryMetadata()
      settledConversation[index] = .assistant(message)
    }
  }
}
