import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("SessionController progress disclosure")
struct SessionControllerTodoDisclosureTests {
  @Test("Progress starts collapsed and restores the user's session choice")
  func defaultsCollapsedAndRestoresChoice() {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/progress-disclosure-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )

    #expect(!controller.isTodosExpanded)

    controller.restoreTodoDisclosure(isExpanded: true)

    #expect(controller.isTodosExpanded)
  }
}
