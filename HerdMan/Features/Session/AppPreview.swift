import Foundation

/// Detects SwiftUI preview rendering, so we can skip launching real agent
/// subprocesses (which would hang against the mock preview transport).
enum AppPreview {
    static var isRunning: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
