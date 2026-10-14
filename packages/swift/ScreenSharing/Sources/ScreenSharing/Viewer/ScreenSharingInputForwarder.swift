#if os(macOS)
  import Foundation

  @MainActor
  public final class ScreenSharingInputForwarder {
    public private(set) var lease: UUID?
    private var sequence: UInt64 = 0
    private let send: (ScreenSharingControlMessage) -> Bool
    public var onLost: ((String?) -> Void)?

    public init(send: @escaping (ScreenSharingControlMessage) -> Bool) { self.send = send }

    public var isActive: Bool { lease != nil }

    public func begin(lease: UUID) {
      self.lease = lease
      sequence = 0
    }

    public func end() { lease = nil }

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
  }
#endif
