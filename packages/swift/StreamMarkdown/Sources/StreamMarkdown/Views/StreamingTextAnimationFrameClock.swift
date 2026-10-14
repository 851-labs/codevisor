import QuartzCore
import SwiftUI

@MainActor
public protocol StreamingTextAnimationFrameClient: AnyObject {
  func streamingTextAnimationFrame(at timestamp: TimeInterval, isFinal: Bool)
}

@MainActor
public final class StreamingTextAnimationFrameClock {
  private struct Entry {
    weak var client: (any StreamingTextAnimationFrameClient)?
    var endTime: TimeInterval
  }

  private var entries: [ObjectIdentifier: Entry] = [:]
  private var requestFrame: (@MainActor () -> Void)?

  public init() {}

  public var activeClientCount: Int { entries.count }

  public func setFrameRequester(_ requestFrame: (@MainActor () -> Void)?) {
    self.requestFrame = requestFrame
    if !entries.isEmpty { requestFrame?() }
  }

  public func update(
    _ client: any StreamingTextAnimationFrameClient,
    until endTime: TimeInterval?
  ) {
    let id = ObjectIdentifier(client)
    guard let endTime else {
      entries.removeValue(forKey: id)
      return
    }
    let now = CACurrentMediaTime()
    guard endTime > now else {
      entries.removeValue(forKey: id)
      client.streamingTextAnimationFrame(at: now, isFinal: true)
      return
    }
    entries[id] = Entry(client: client, endTime: endTime)
    requestFrame?()
  }

  public func remove(_ client: any StreamingTextAnimationFrameClient) {
    entries.removeValue(forKey: ObjectIdentifier(client))
  }

  public func tick(at timestamp: TimeInterval) {
    for (id, entry) in entries {
      guard let client = entry.client else {
        entries.removeValue(forKey: id)
        continue
      }
      let isFinal = timestamp >= entry.endTime
      client.streamingTextAnimationFrame(at: timestamp, isFinal: isFinal)
      if isFinal {
        entries.removeValue(forKey: id)
      }
    }
    if !entries.isEmpty { requestFrame?() }
  }
}

private struct StreamingTextAnimationFrameClockKey: EnvironmentKey {
  static let defaultValue: StreamingTextAnimationFrameClock? = nil
}

public extension EnvironmentValues {
  var streamingTextAnimationFrameClock: StreamingTextAnimationFrameClock? {
    get { self[StreamingTextAnimationFrameClockKey.self] }
    set { self[StreamingTextAnimationFrameClockKey.self] = newValue }
  }
}
