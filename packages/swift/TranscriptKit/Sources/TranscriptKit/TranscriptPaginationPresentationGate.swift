import Foundation

/// Owns the user-visible lifetime of one reverse-pagination operation.
///
/// Network completion is intentionally not the terminal state: native
/// transcript views can defer a prepend while scrolling, so feedback remains
/// visible until the virtualizer confirms that the fetched rows have entered
/// its document geometry.
public struct TranscriptPaginationPresentationTarget: Sendable, Equatable {
    public let token: UInt64
    public let oldestRowKey: String

    public init(token: UInt64, oldestRowKey: String) {
        self.token = token
        self.oldestRowKey = oldestRowKey
    }
}

public struct TranscriptPaginationPresentationGate: Sendable, Equatable {
    private var nextToken: UInt64 = 0
    public private(set) var activeToken: UInt64?
    public private(set) var presentationTarget: TranscriptPaginationPresentationTarget?

    public init() {}

    public var isPresented: Bool { activeToken != nil }

    /// Starts feedback only when another page is known to exist. The returned
    /// token binds the eventual response and native-layout acknowledgement to
    /// this exact request.
    @discardableResult
    public mutating func begin(hasOlderHistory: Bool) -> UInt64? {
        guard hasOlderHistory, activeToken == nil else { return nil }
        nextToken &+= 1
        activeToken = nextToken
        presentationTarget = nil
        return nextToken
    }

    /// A non-empty page keeps feedback alive until native presentation. Empty
    /// pages and failures end it immediately because there is no new document
    /// geometry for the virtualizer to commit.
    public mutating func requestDidFinish(
        token: UInt64,
        insertedItemCount: Int,
        oldestRowKey: String?
    ) {
        guard activeToken == token else { return }
        guard insertedItemCount > 0, let oldestRowKey else {
            activeToken = nil
            presentationTarget = nil
            return
        }
        presentationTarget = .init(token: token, oldestRowKey: oldestRowKey)
    }

    /// Returns true only when the matching native virtualizer commit completes
    /// the active pagination presentation.
    @discardableResult
    public mutating func didPresent(token: UInt64) -> Bool {
        guard activeToken == token, presentationTarget?.token == token else { return false }
        activeToken = nil
        presentationTarget = nil
        return true
    }

    public mutating func cancel(token: UInt64? = nil) {
        guard token == nil || activeToken == token else { return }
        activeToken = nil
        presentationTarget = nil
    }
}
