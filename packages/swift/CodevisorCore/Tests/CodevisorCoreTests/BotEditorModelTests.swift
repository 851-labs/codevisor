import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("BotEditorModel")
struct BotEditorModelTests {
  @Test("Editing a bot starts from its name and icon and only needs a name to save")
  func editingNeedsOnlyAName() throws {
    let environment = AppEnvironment.preview(seedProjects: [], seedSessions: [])
    let bot = try #require(Bot(serverId: CodevisorMachine.local.id, record: .fixture(name: "Helper")))
    let editor = BotEditorModel(target: .edit(bot), environment: environment)

    #expect(editor.name == "Helper")
    #expect(editor.symbolName == bot.symbolName)
    #expect(editor.canSave)
    editor.name = "   "
    #expect(!editor.canSave)
  }

  @Test("A new bot keeps each chosen project once and drops them when its machine changes")
  func creatingTracksProjectsPerMachine() {
    let environment = AppEnvironment.preview(seedProjects: [], seedSessions: [])
    let editor = BotEditorModel(target: .create, environment: environment)
    let project = UUID()

    editor.name = "Helper"
    editor.addProject(project)
    editor.addProject(project)
    #expect(editor.projectIds == [project])
    #expect(!editor.canSave)

    editor.serverId = "another-machine"
    #expect(editor.projectIds.isEmpty)
  }
}
