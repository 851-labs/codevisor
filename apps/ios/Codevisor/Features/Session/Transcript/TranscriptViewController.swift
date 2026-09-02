import CodevisorCore
import CodevisorUI
import StreamMarkdown
import SwiftUI
import UIKit

/// The only controller SwiftUI installs for a transcript. It is a real UIKit
/// containment boundary: row hosting controllers are descendants of this
/// controller, not siblings injected into the navigation destination.
@MainActor
final class TranscriptViewController: UIViewController {
    private let transcriptScrollView = VirtualizedTranscriptScrollView()

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root

        transcriptScrollView.hostingParent = self
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(transcriptScrollView)
        NSLayoutConstraint.activate([
            transcriptScrollView.topAnchor.constraint(equalTo: root.topAnchor),
            transcriptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    func configure(_ input: TranscriptSurfaceInput, callbacks: TranscriptSurfaceCallbacks) {
        loadViewIfNeeded()
        transcriptScrollView.configure(input, callbacks: callbacks)
    }

    func prepareForDismantle() {
        transcriptScrollView.prepareForDismantle()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        transcriptScrollView.discardParkedHosts()
    }
}
