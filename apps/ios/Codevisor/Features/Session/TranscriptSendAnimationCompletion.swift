import QuartzCore

/// Retained for the lifetime of the Core Animation group so first-send
/// promotion can wait for the visible row's actual presentation completion.
final class TranscriptSendAnimationCompletion: NSObject, CAAnimationDelegate {
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func animationDidStop(_: CAAnimation, finished: Bool) {
        completion(finished)
    }
}
