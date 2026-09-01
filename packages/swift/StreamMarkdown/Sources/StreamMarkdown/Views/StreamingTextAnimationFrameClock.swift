import QuartzCore
import SwiftUI

/// A native text surface that can redraw its active glyph fades from a shared
/// transcript display clock.
@MainActor
public protocol StreamingTextAnimationFrameClient: AnyObject {
    /// `isFinal` guarantees one terminal repaint before the clock retires the
    /// client. Native scroll views may coalesce every intermediate offscreen
    /// invalidation, but they must not retain transparent backing pixels after
    /// the fade deadline has passed.
    func streamingTextAnimationFrame(at timestamp: TimeInterval, isFinal: Bool)
}

/// Multiplexes one transcript display link across every mounted TextKit
/// surface. Standalone Markdown views retain their local display-link fallback;
/// transcript rows inject this clock so dozens of blocks do not each schedule
/// an identical callback on every physical frame.
@MainActor
public final class StreamingTextAnimationFrameClock {
    private struct Entry {
        weak var client: (any StreamingTextAnimationFrameClient)?
        var endTime: TimeInterval
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var requestFrame: (@MainActor () -> Void)?

    public init() {}

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
            // A runway view can attach after its fade deadline. Give it the
            // same terminal repaint as an actively-driven client instead of
            // waiting for a later scroll or content update to invalidate it.
            client.streamingTextAnimationFrame(at: now, isFinal: true)
            return
        }
        entries[id] = Entry(client: client, endTime: endTime)
        requestFrame?()
    }

    public func remove(_ client: any StreamingTextAnimationFrameClient) {
        entries.removeValue(forKey: ObjectIdentifier(client))
    }

    /// Draws one shared timestamp and re-arms the native link only while at
    /// least one live fade remains.
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
