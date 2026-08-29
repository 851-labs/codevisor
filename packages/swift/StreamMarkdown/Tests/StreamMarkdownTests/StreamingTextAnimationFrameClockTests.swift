import QuartzCore
import Testing
@testable import StreamMarkdown

@MainActor
struct StreamingTextAnimationFrameClockTests {
    private final class Client: StreamingTextAnimationFrameClient {
        var timestamps: [TimeInterval] = []

        func streamingTextAnimationFrame(at timestamp: TimeInterval) {
            timestamps.append(timestamp)
        }
    }

    @Test("One shared request chain drives a client through its final fade frame")
    func sharedClockRearmsOnlyWhileActive() {
        let clock = StreamingTextAnimationFrameClock()
        let client = Client()
        var requestedFrames = 0
        clock.setFrameRequester { requestedFrames += 1 }
        let start = CACurrentMediaTime()
        let end = start + 0.5

        clock.update(client, until: end)
        #expect(requestedFrames == 1)
        clock.tick(at: start)
        #expect(client.timestamps == [start])
        #expect(requestedFrames == 2)
        clock.tick(at: end)
        #expect(client.timestamps == [start, end])
        #expect(requestedFrames == 2)
    }
}
