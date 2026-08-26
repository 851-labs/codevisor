import CodevisorUI
import StreamMarkdown

enum ComposerGlassElements {
    static func visible(
        hasTodos: Bool,
        showsGoal: Bool,
        hasQueuedPrompts: Bool
    ) -> [ComposerGlassElement] {
        var elements: [ComposerGlassElement] = []
        if hasTodos {
            elements.append(.todos)
        }
        if showsGoal {
            elements.append(.goal)
        }
        if hasQueuedPrompts {
            elements.append(.queue)
        }
        elements.append(.composer)
        return elements
    }
}

extension StreamingTextAnimationVisibility {
    static var initiallyHidden: StreamingTextAnimationVisibility {
        StreamingTextAnimationVisibility(initiallyVisible: false)
    }
}
