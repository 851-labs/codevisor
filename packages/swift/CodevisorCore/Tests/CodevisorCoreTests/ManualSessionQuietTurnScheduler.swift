import Foundation
@testable import CodevisorCore

@MainActor
final class ManualSessionQuietTurnScheduler {
    private typealias Operation = SessionQuietTurnScheduler.Operation

    private var nextID = 0
    private var pending: [Int: Operation] = [:]
    private(set) var callCount = 0

    lazy var scheduler = SessionQuietTurnScheduler { [weak self] _, operation in
        guard let self else { return SessionQuietTurnCancellation {} }
        nextID += 1
        let id = nextID
        callCount += 1
        pending[id] = operation
        return SessionQuietTurnCancellation { [weak self] in
            self?.pending[id] = nil
        }
    }

    func advance() async {
        let operations = pending.sorted { $0.key < $1.key }.map(\.value)
        pending.removeAll()
        for operation in operations {
            await operation()
        }
    }
}
