import UIKit

/// SwiftUI owns these stable containers and each promotion surface owns its
/// own editor. Keeping the editor inside its controller hierarchy is required
/// for UIKit to open the software keyboard from a programmatic focus request.
final class ComposerTextViewContainer: UIView {
    var activation: (() -> Void)?
    var localEditor: HeightReportingTextView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        activateIfPossible()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ComposerTextViewHandoffRegistry.layoutEditor(ownedBy: self)
        subviews.forEach { $0.frame = bounds }
    }

    func activateIfPossible() {
        activation?()
    }
}
