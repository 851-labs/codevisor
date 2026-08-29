import Foundation

/// Serializes live-row projection and retains only the newest waiting request.
/// MD4C projection is intentionally whole-document, so allowing every ACP
/// revision to leave behind an uncancellable detached parse creates an
/// unbounded CPU backlog on fast streams. This worker permits one parse in
/// flight and one replaceable pending snapshot.
@MainActor
public final class TranscriptActiveProjectionWorker {
    public struct Request: Equatable, Sendable {
        public let revision: UInt64
        public let projectedID: UUID
        public let item: ConversationItem
        public let waitingOnBackgroundTask: String?

        public init(
            revision: UInt64,
            projectedID: UUID,
            item: ConversationItem,
            waitingOnBackgroundTask: String?
        ) {
            self.revision = revision
            self.projectedID = projectedID
            self.item = item
            self.waitingOnBackgroundTask = waitingOnBackgroundTask
        }
    }

    public struct Output: Sendable {
        public let request: Request
        public let rows: [TranscriptPresentationRow]
    }

    typealias Projector = @Sendable (ConversationItem, String?) -> [TranscriptPresentationRow]

    private struct PendingWork {
        let generation: UInt64
        let request: Request
        let completion: @MainActor (Output) -> Void
    }

    private let projector: Projector
    private var generation: UInt64 = 0
    private var pendingWork: PendingWork?
    private var processingTask: Task<Void, Never>?

    public convenience init() {
        self.init { item, waiting in
            TranscriptActiveRowProjection.rows(
                for: item,
                waitingOnBackgroundTask: waiting
            )
        }
    }

    init(projector: @escaping Projector) {
        self.projector = projector
    }

    public func submit(
        _ request: Request,
        completion: @escaping @MainActor (Output) -> Void
    ) {
        generation &+= 1
        pendingWork = PendingWork(
            generation: generation,
            request: request,
            completion: completion
        )
        startIfNeeded()
    }

    public func cancel() {
        generation &+= 1
        pendingWork = nil
        processingTask?.cancel()
    }

    private func startIfNeeded() {
        guard processingTask == nil, pendingWork != nil else { return }
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let work = self.takePendingWork() {
                let projector = self.projector
                let request = work.request
                let rows = await Task.detached(priority: .userInitiated) {
                    projector(request.item, request.waitingOnBackgroundTask)
                }.value
                guard !Task.isCancelled else { break }
                if work.generation == self.generation {
                    work.completion(Output(request: request, rows: rows))
                }
            }
            self.processingTask = nil
            // A submission can land after the loop observes an empty slot but
            // before this task releases ownership.
            self.startIfNeeded()
        }
    }

    private func takePendingWork() -> PendingWork? {
        defer { pendingWork = nil }
        return pendingWork
    }
}
