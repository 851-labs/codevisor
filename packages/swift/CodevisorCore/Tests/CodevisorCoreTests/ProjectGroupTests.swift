import Foundation
import Testing

@testable import CodevisorCore

/// Cross-machine project linking: records that share a server-derived repo
/// key fold into one group; everything else stands alone.
@MainActor
@Suite("ProjectGroup")
struct ProjectGroupTests {
  private func project(
    _ name: String,
    serverId: String,
    repoKey: String? = nil,
    createdAt: TimeInterval = 0,
    isScratch: Bool = false
  ) -> Project {
    var project = Project.fromFolder(
      URL(fileURLWithPath: "/srv/\(serverId)/\(name)"),
      serverId: serverId,
      createdAt: Date(timeIntervalSince1970: createdAt)
    )
    project.name = name
    project.repoKey = repoKey
    project.isScratch = isScratch
    return project
  }

  private func model(_ projects: [Project], sessions: [ChatSession] = []) -> ProjectListModel {
    let projectRepository = DefaultProjectRepository(store: InMemoryStore())
    projectRepository.save(projects)
    let sessionRepository = DefaultSessionRepository(store: InMemoryStore())
    sessionRepository.save(sessions)
    return ProjectListModel(
      projectRepository: projectRepository,
      sessionRepository: sessionRepository
    )
  }

  @Test("Projects with the same repo key on different machines form one group")
  func linksAcrossMachines() {
    let laptop = project("widget", serverId: "laptop", repoKey: "github.com/acme/widget", createdAt: 20)
    let desktop = project("Widget Checkout", serverId: "desktop", repoKey: "github.com/acme/widget", createdAt: 10)
    let docs = project("docs", serverId: "laptop", repoKey: "github.com/acme/docs", createdAt: 30)
    let plain = project("notes", serverId: "desktop", createdAt: 40)

    let groups = ProjectGroup.grouping([plain, docs, laptop, desktop])

    #expect(
      groups.map(\.id) == [
        "project|desktop|\(plain.id.uuidString)",
        "repo|github.com/acme/docs",
        "repo|github.com/acme/widget",
      ])
    let widget = groups[2]
    #expect(widget.members.count == 2)
    // The oldest record names the group and leads its members.
    #expect(widget.name == "Widget Checkout")
    #expect(widget.primary.serverId == "desktop")
    #expect(widget.serverIds == ["desktop", "laptop"])
    #expect(widget.member(on: "laptop")?.id == laptop.id)
    #expect(widget.member(on: "cloud") == nil)
    #expect(widget.contains(laptop))
    #expect(!widget.contains(plain))
    #expect(ProjectGroup.groupID(for: laptop) == widget.id)
  }

  @Test("Projects without a repo key never link, and scratch never links")
  func unlinkedProjectsStandAlone() {
    let one = project("same-name", serverId: "laptop", createdAt: 1)
    let two = project("same-name", serverId: "desktop", createdAt: 2)
    let scratch = project("burrito", serverId: "laptop", repoKey: "github.com/acme/widget", isScratch: true)
    let real = project("widget", serverId: "desktop", repoKey: "github.com/acme/widget")

    let groups = ProjectGroup.grouping([one, two, scratch, real])

    #expect(groups.count == 4)
    #expect(groups.allSatisfy { $0.members.count == 1 })
    #expect(ProjectGroup.groupID(for: scratch).hasPrefix("project|"))
    #expect(ProjectGroup.groupID(for: real) == "repo|github.com/acme/widget")
  }

  @Test("Fleet groups exclude scratch projects and pool every member's sessions")
  func fleetGroupsAndSessions() {
    let laptop = project("widget", serverId: "laptop", repoKey: "github.com/acme/widget", createdAt: 5)
    let desktop = project("widget", serverId: "desktop", repoKey: "github.com/acme/widget", createdAt: 1)
    let scratch = project("burrito", serverId: "laptop", createdAt: 9, isScratch: true)
    func session(_ project: Project, title: String, at: TimeInterval) -> ChatSession {
      ChatSession(
        projectId: project.id,
        serverId: project.serverId,
        harnessId: "codex",
        title: title,
        origin: .codevisor,
        createdAt: Date(timeIntervalSince1970: at)
      )
    }
    let model = model(
      [laptop, desktop, scratch],
      sessions: [
        session(laptop, title: "laptop-old", at: 10),
        session(desktop, title: "desktop-new", at: 30),
        session(laptop, title: "laptop-mid", at: 20),
        session(scratch, title: "scratch", at: 40),
      ]
    )

    let groups = model.fleetActiveProjectGroups
    #expect(groups.map(\.id) == ["repo|github.com/acme/widget"])
    #expect(model.fleetSessions(in: groups[0]).map(\.title) == ["desktop-new", "laptop-mid", "laptop-old"])
    #expect(model.fleetProjectGroup(containing: laptop)?.id == groups[0].id)
    #expect(model.fleetProjectGroup(containing: scratch) == nil)
    // Picking the group picks the machine that used it most recently.
    #expect(model.mostRecentlyUsedMember(of: groups[0]).serverId == "desktop")
  }

  @Test("A group with no session history resolves to its primary member")
  func idleGroupResolvesToPrimary() {
    let laptop = project("widget", serverId: "laptop", repoKey: "github.com/acme/widget", createdAt: 5)
    let desktop = project("widget", serverId: "desktop", repoKey: "github.com/acme/widget", createdAt: 1)
    let model = model([laptop, desktop])
    let group = model.fleetActiveProjectGroups[0]
    #expect(model.mostRecentlyUsedMember(of: group).serverId == "desktop")
  }

  @Test("Workspace-recency ordering places a group where its first member appears")
  func workspaceRecencyOrdering() {
    let laptop = project("widget", serverId: "laptop", repoKey: "github.com/acme/widget", createdAt: 5)
    let desktop = project("widget", serverId: "desktop", repoKey: "github.com/acme/widget", createdAt: 1)
    let docs = project("docs", serverId: "laptop", repoKey: "github.com/acme/docs", createdAt: 9)
    let model = model([laptop, desktop, docs])
    func workspace(_ project: Project, createdAt: TimeInterval) -> Workspace {
      Workspace(
        name: "Workspace",
        rootDirectory: nil,
        serverId: project.serverId,
        projectId: project.id,
        centerTree: .leaf(PaneGroupState()),
        bottomGroup: PaneGroupState(),
        createdAt: Date(timeIntervalSince1970: createdAt)
      )
    }

    // The widget group's most recent workspace is on the desktop; it
    // outranks docs, whose only workspace is older.
    let ordered = model.fleetActiveProjectGroupsByWorkspaceRecency([
      workspace(docs, createdAt: 10),
      workspace(desktop, createdAt: 20),
    ])
    #expect(ordered.map(\.id) == ["repo|github.com/acme/widget", "repo|github.com/acme/docs"])
  }

  @Test("Repo identity survives the client cache round trip")
  func codableRoundTrip() throws {
    let original = project("widget", serverId: "laptop", repoKey: "github.com/acme/widget")
    var withUrl = original
    withUrl.repoUrl = "git@github.com:acme/widget.git"
    let data = try JSONEncoder().encode(withUrl)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded.repoUrl == "git@github.com:acme/widget.git")
    #expect(decoded.repoKey == "github.com/acme/widget")
    #expect(decoded == withUrl)
  }
}
