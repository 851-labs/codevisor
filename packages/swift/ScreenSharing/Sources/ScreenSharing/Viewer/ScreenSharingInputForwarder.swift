#if os(macOS)
  import Foundation

  @MainActor
  public final class ScreenSharingInputForwarder {
    public typealias Heartbeat = @Sendable (_ lease: UUID) -> Bool

    public private(set) var lease: UUID?
    private var sequence: UInt64 = 0
    private let send: (ScreenSharingControlMessage) -> Bool
    private let heartbeat: Heartbeat?
    private let heartbeatInterval: Duration
    private var keepingAlive: Task<Void, Never>?
    public var onLost: ((String?) -> Void)?

    public init(
      send: @escaping (ScreenSharingControlMessage) -> Bool, heartbeat: Heartbeat? = nil,
      heartbeatInterval: Duration = .seconds(1)
    ) {
      self.send = send
      self.heartbeat = heartbeat
      self.heartbeatInterval = heartbeatInterval
    }

    isolated deinit {
      keepingAlive?.cancel()
    }

    public var isActive: Bool { lease != nil }
    public var keepsLeaseAlive: Bool { keepingAlive != nil }

    public func begin(lease: UUID) {
      end()
      self.lease = lease
      sequence = 0
      guard let heartbeat else { return }

      keepingAlive = Task { [heartbeatInterval] in await Self.keepAlive(lease, every: heartbeatInterval, heartbeat) }
    }

    public func end() {
      lease = nil
      keepingAlive?.cancel()
      keepingAlive = nil
    }

    public func forward(_ event: ScreenSharingInputEvent) {
      guard let lease, event.isValid else { return }
      guard sequence < UInt64.max else {
        end()
        onLost?(nil)
        return
      }
      sequence += 1
      if !send(.input(lease: lease, sequence: sequence, event: event)) {
        end()
        onLost?("Control paused because the connection could not keep up. Request control again.")
      }
    }

    @concurrent
    private nonisolated static func keepAlive(_ lease: UUID, every interval: Duration, _ heartbeat: Heartbeat) async {
      while !Task.isCancelled {
        _ = heartbeat(lease)
        do { try await Task.sleep(for: interval) } catch { return }
      }
    }
  }
#endif
