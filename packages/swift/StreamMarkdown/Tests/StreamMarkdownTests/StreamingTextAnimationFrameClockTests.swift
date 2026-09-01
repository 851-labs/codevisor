import QuartzCore
import Testing
@testable import StreamMarkdown

@MainActor
struct StreamingTextAnimationFrameClockTests {
    private final class Client: StreamingTextAnimationFrameClient {
        struct Frame: Equatable {
            let timestamp: TimeInterval
            let isFinal: Bool
        }

        var frames: [Frame] = []

        func streamingTextAnimationFrame(at timestamp: TimeInterval, isFinal: Bool) {
            frames.append(Frame(timestamp: timestamp, isFinal: isFinal))
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
        #expect(client.frames == [Client.Frame(timestamp: start, isFinal: false)])
        #expect(requestedFrames == 2)
        clock.tick(at: end)
        #expect(
            client.frames == [
                Client.Frame(timestamp: start, isFinal: false),
                Client.Frame(timestamp: end, isFinal: true),
            ]
        )
        #expect(requestedFrames == 2)
    }

    @Test("A client mounted after its deadline receives an immediate terminal frame")
    func expiredRegistrationFinishesImmediately() {
        let clock = StreamingTextAnimationFrameClock()
        let client = Client()
        var requestedFrames = 0
        clock.setFrameRequester { requestedFrames += 1 }

        clock.update(client, until: CACurrentMediaTime() - 1)

        #expect(client.frames.count == 1)
        #expect(client.frames.first?.isFinal == true)
        #expect(requestedFrames == 0)
    }
}
