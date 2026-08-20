import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("SessionController question presentations")
struct SessionControllerQuestionPresentationTests {
    @Test("Browser setup opens the installer on the session computer")
    func opensBrowserExtensionInstaller() async throws {
        let sessionId = UUID()
        let client = FakeSessionServerClient(sessionId: sessionId)
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/browser-question-tests"))
        let controller = SessionController(
            project: project,
            configCache: ConfigOptionCache(store: InMemoryStore()),
            serverClient: client
        )

        try await controller.openBrowserExtensionInstaller()

        #expect(client.browserExtensionInstallerOpenCount == 1)
    }
}
