import Foundation
import Testing
@testable import CodevisorCore

private actor ProjectSetupFakeClient: CodevisorServerClienting {
  var source = ServerProjectSetupSource(projectId: "", folderPath: "")
  var envContents: [String: String] = [:]
  var setupResults: [Result<ServerProject, CodevisorServerClientError>] = []
  var authFlows: [ServerGitAuthFlow] = []
  private(set) var setupRequests: [ServerProjectSetupRequest] = []
  private(set) var readPaths: [[String]] = []
  private(set) var publishes: [(url: String, initialize: Bool)] = []

  func configure(
    source: ServerProjectSetupSource? = nil,
    envContents: [String: String]? = nil,
    setupResults: [Result<ServerProject, CodevisorServerClientError>]? = nil,
    authFlows: [ServerGitAuthFlow]? = nil
  ) {
    if let authFlows { self.authFlows = authFlows }
    if let source { self.source = source }
    if let envContents { self.envContents = envContents }
    if let setupResults { self.setupResults = setupResults }
  }

  func projectSetupSource(projectId: UUID) async throws -> ServerProjectSetupSource { source }

  func readProjectEnvFiles(projectId: UUID, paths: [String]) async throws -> [ServerProjectEnvFileContent] {
    readPaths.append(paths)
    return paths.map { ServerProjectEnvFileContent(path: $0, contents: envContents[$0] ?? "") }
  }

  func publishProjectRemote(projectId: UUID, url: String, initialize: Bool) async throws -> ServerProject {
    publishes.append((url, initialize))
    return ServerProject(
      id: projectId.uuidString, name: "notes", origin: .codevisor, createdAt: "2026-10-21T12:00:00.000Z",
      locations: [], repoUrl: url)
  }

  func setUpProjectFromGit(_ request: ServerProjectSetupRequest) async throws -> ServerProject {
    setupRequests.append(request)
    return try setupResults.removeFirst().get()
  }

  func startGitAuth(host: String) async throws -> ServerGitAuthFlow {
    try nextAuthFlow()
  }

  func gitAuthFlow(id: String) async throws -> ServerGitAuthFlow {
    try nextAuthFlow()
  }

  private func nextAuthFlow() throws -> ServerGitAuthFlow {
    guard let flow = authFlows.first else { throw CodevisorServerClientError.invalidResponse }
    if authFlows.count > 1 { authFlows.removeFirst() }
    return flow
  }

  func health() async throws -> ServerHealth { ServerHealth(ok: true, version: "0.1.0", database: "ready") }
  func info() async throws -> ServerInfo { throw CodevisorServerClientError.invalidResponse }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities {
    throw CodevisorServerClientError.invalidResponse
  }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func deleteProject(id: UUID) async throws {}
  func deleteProject(id: UUID, deletingFiles: Bool) async throws {}
  func updateProjectWorktreeBase(id: UUID, worktreeBase: ProjectWorktreeBase?) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateProjectDefaultRunLocation(
    id: UUID, defaultRunLocation: ProjectRunLocation?
  ) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession? { nil }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    throw CodevisorServerClientError.invalidResponse
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func upsertProject(_ project: Project) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func listSessions() async throws -> [ServerSession] { [] }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteSession(id: UUID) async throws {}
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
  nonisolated func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { $0.finish() }
  }
}

@MainActor
@Suite("Project setup on another machine")
struct ProjectMachineSetupTests {
  private let sourceProject = Project(
    serverId: "mac",
    name: "widget",
    locations: [],
    repoUrl: "git@github.com:acme/widget.git",
    repoKey: "github.com/acme/widget"
  )

  private func clonedProject(id: String) -> ServerProject {
    ServerProject(
      id: id,
      name: "widget",
      origin: .codevisor,
      createdAt: "2026-10-21T12:00:00.000Z",
      locations: [
        ServerProjectLocation(
          id: "location", projectId: id, serverId: "studio", folderPath: "/Users/me/src/widget",
          createdAt: "2026-10-21T12:00:00.000Z", isGitRepository: true)
      ],
      repoUrl: "git@github.com:acme/widget.git"
    )
  }

  private func makeSetup(
    source: ProjectSetupFakeClient,
    target: ProjectSetupFakeClient,
    adopted: @escaping (Project) -> Void = { _ in }
  ) -> ProjectMachineSetup {
    ProjectMachineSetup(
      clientFor: { $0 == "mac" ? source : target },
      machineName: { $0 == "mac" ? "MacBook" : "Studio" },
      isReachable: { _ in true },
      adopt: adopted
    )
  }

  @Test("copies the source's env files and the repository's settings to the new clone")
  func copiesCheckedEnvFiles() async throws {
    let source = ProjectSetupFakeClient()
    let target = ProjectSetupFakeClient()
    let clonedId = UUID().uuidString
    await source.configure(
      source: ServerProjectSetupSource(
        projectId: sourceProject.id.uuidString,
        folderPath: "/Users/me/src/widget",
        homeRelativePath: "src/widget",
        envFiles: [
          ServerProjectEnvFile(path: ".env", size: 8),
          ServerProjectEnvFile(path: "apps/web/.env.local", size: 6),
        ]
      ),
      envContents: [".env": "TOKEN=1\n", "apps/web/.env.local": "A=1\n"]
    )
    await target.configure(setupResults: [.success(clonedProject(id: clonedId))])
    var adopted: [Project] = []
    let setup = makeSetup(source: source, target: target) { adopted.append($0) }
    var configured = sourceProject
    configured.locations = [
      ProjectLocation(
        projectId: sourceProject.id, serverId: "mac", folderPath: "/Users/me/src/widget",
        isGitRepository: true)
    ]
    configured.worktreeBase = ProjectWorktreeBase(remote: "origin", branch: "develop")
    configured.defaultRunLocation = .newWorktree
    let group = try #require(ProjectGroup.grouping([configured]).first)

    await setup.prepare(group: group, targetServerId: "studio", preferredSource: nil)
    let plan = try #require(setup.plan)
    #expect(plan.copiesEnvFiles)
    setup.confirm()
    try await waitUntil {
      if case .finished = setup.phase { return true }
      return false
    }

    let request = try #require(await target.setupRequests.first)
    #expect(request.url == "git@github.com:acme/widget.git")
    #expect(request.homeRelativePath == "src/widget")
    #expect(request.worktreeBase == ProjectWorktreeBase(remote: "origin", branch: "develop"))
    #expect(request.defaultRunLocation == .newWorktree)
    #expect(
      request.envFiles == [
        ServerProjectEnvFileContent(path: ".env", contents: "TOKEN=1\n"),
        ServerProjectEnvFileContent(path: "apps/web/.env.local", contents: "A=1\n"),
      ])
    #expect(await source.readPaths == [[".env", "apps/web/.env.local"]])
    #expect(adopted.map(\.id.uuidString) == [clonedId])
    #expect(adopted.first?.serverId == "studio")
    #expect(setup.progress == .init(label: "Starting chat…", fraction: 1))
  }

  @Test("moves to GitHub sign-in when the target can't authenticate, then retries the same plan")
  func offersSignInAndRetries() async throws {
    let source = ProjectSetupFakeClient()
    let target = ProjectSetupFakeClient()
    let clonedId = UUID().uuidString
    await target.configure(setupResults: [
      .failure(.httpStatus(422, #"{"error":"fatal: Authentication failed","code":"auth_failed"}"#)),
      .success(clonedProject(id: clonedId)),
    ])
    let setup = makeSetup(source: source, target: target)
    let group = try #require(ProjectGroup.grouping([sourceProject]).first)

    await setup.prepare(group: group, targetServerId: "studio", preferredSource: nil)
    setup.confirm()
    try await waitUntil {
      if case .signingIn = setup.phase { return true }
      return false
    }
    guard case let .signingIn(_, signIn) = setup.phase else {
      Issue.record("Expected the sheet to move to sign-in")
      return
    }
    #expect(signIn.machineName == "Studio")

    setup.retry()
    try await waitUntil {
      if case .finished = setup.phase { return true }
      return false
    }
    let requests = await target.setupRequests
    #expect(requests.count == 2)
    #expect(requests[0].url == requests[1].url)
    #expect(requests[0].id != requests[1].id)
  }

  @Test("installs the GitHub CLI on a target without it, then shows the device code")
  func installsMissingCliBeforeSignIn() async throws {
    let source = ProjectSetupFakeClient()
    let target = ProjectSetupFakeClient()
    let flow = ServerGitAuthFlow(id: "flow", host: "github.com", provider: "github", state: .starting)
    var installing = flow
    installing.installing = true
    var waiting = flow
    waiting.state = .waiting
    waiting.userCode = "AB12-CD34"
    waiting.verificationUrl = "https://github.com/login/device"
    await target.configure(
      setupResults: [
        .failure(.httpStatus(422, #"{"error":"fatal: Authentication failed","code":"auth_failed"}"#))
      ],
      authFlows: [installing, waiting]
    )
    let setup = makeSetup(source: source, target: target)
    let group = try #require(ProjectGroup.grouping([sourceProject]).first)

    await setup.prepare(group: group, targetServerId: "studio", preferredSource: nil)
    setup.confirm()
    try await waitUntil { signInStep(of: setup) == .installing(.github) }
    try await waitUntil { signInStep(of: setup) == .waiting(.github, waiting) }

    #expect(GitHostProvider.github.cliName == "GitHub CLI")
  }

  @Test("fails a sign-in whose CLI install failed, and installs again on Try Again")
  func retriesFailedInstall() async throws {
    let client = ProjectSetupFakeClient()
    var installing = ServerGitAuthFlow(id: "flow", host: "github.com", provider: "github", state: .starting)
    installing.installing = true
    var failed = installing
    failed.installing = nil
    failed.state = .error
    failed.message = "Couldn't download GitHub CLI. Check this machine's internet connection."
    await client.configure(authFlows: [installing, failed])
    let model = GitSignInModel(
      client: client, machineName: "Studio", suggestedHost: "github.com", pollInterval: .milliseconds(1))

    model.signIn(with: .github)
    try await waitUntil { model.step == .failed(.github, message: failed.message ?? "") }
    await client.configure(authFlows: [installing])
    model.signIn(with: .github)
    try await waitUntil { model.step == .installing(.github) }

    #expect(model.provider == .github)
  }

  private func signInStep(of setup: ProjectMachineSetup) -> GitSignInModel.Step? {
    guard case let .signingIn(_, model) = setup.phase else { return nil }
    return model.step
  }

  @Test("explains a missing repository without starting sign-in, and signs in only when asked")
  func explainsMissingRepository() async throws {
    let source = ProjectSetupFakeClient()
    let target = ProjectSetupFakeClient()
    await target.configure(setupResults: [
      .failure(.httpStatus(422, #"{"error":"remote: Repository not found.","code":"repo_not_found"}"#))
    ])
    let setup = makeSetup(source: source, target: target)
    let group = try #require(ProjectGroup.grouping([sourceProject]).first)

    await setup.prepare(group: group, targetServerId: "studio", preferredSource: nil)
    setup.confirm()
    try await waitUntil {
      if case .failed = setup.phase { return true }
      return false
    }

    #expect(
      setup.screen(showing: setup.plan)
        == .init(
          symbol: "questionmark.folder",
          title: "Repository not found",
          message: "acme/widget doesn't exist, or Studio's GitHub account can't see it."
        ))
    #expect(setup.offersSignIn)

    setup.signIn()
    guard case let .signingIn(_, signIn) = setup.phase else {
      Issue.record("Expected Sign In to move the sheet to sign-in")
      return
    }
    #expect(signIn.machineName == "Studio")
  }

  @Test("skips env files when unchecked and explains a project with no remote and no source")
  func skipsEnvFilesAndRejectsNoRemote() async throws {
    let source = ProjectSetupFakeClient()
    let target = ProjectSetupFakeClient()
    await source.configure(
      source: ServerProjectSetupSource(
        projectId: sourceProject.id.uuidString,
        folderPath: "/Users/me/src/widget",
        envFiles: [ServerProjectEnvFile(path: ".env", size: 8)]
      ))
    await target.configure(setupResults: [.success(clonedProject(id: UUID().uuidString))])
    let setup = makeSetup(source: source, target: target)
    let group = try #require(ProjectGroup.grouping([sourceProject]).first)
    var local = sourceProject
    local.repoUrl = nil
    local.repoKey = nil
    local.serverId = "studio"
    let noRemote = ProjectGroup(solo: local)

    await setup.prepare(group: noRemote, targetServerId: "studio", preferredSource: nil)
    #expect(setup.phase == .unavailable(projectName: "widget", machineName: "Studio"))
    setup.cancel()
    await setup.prepare(group: group, targetServerId: "studio", preferredSource: nil)
    setup.setCopiesEnvFiles(false)
    setup.confirm()
    try await waitUntil {
      if case .finished = setup.phase { return true }
      return false
    }

    #expect(await source.readPaths.isEmpty)
    #expect(await target.setupRequests.first?.envFiles == nil)
  }

  @Test("describes each git phase with its own percent and the detail git reports")
  func cloneProgress() {
    let receiving = ProjectMachineSetup.progress(
      for: ProjectCloneProgress(
        stage: "receiving", percent: 45, completed: 556, total: 999, bytes: 12_300_000,
        bytesPerSecond: 5_600_000))
    #expect(receiving.label == "Receiving objects…")
    #expect(receiving.fraction == 0.45)
    #expect(receiving.detail?.contains(" · ") == true)
    #expect(receiving.detail?.hasSuffix("/s") == true)
    let countsOnly = ProjectMachineSetup.progress(
      for: ProjectCloneProgress(stage: "receiving", percent: 10, completed: 56, total: 999))
    #expect(countsOnly.detail == "56 of 999 objects")
    let deltas = ProjectMachineSetup.progress(
      for: ProjectCloneProgress(stage: "resolving", percent: 50, completed: 60, total: 120))
    #expect(deltas == .init(label: "Resolving deltas…", fraction: 0.5, detail: "60 of 120"))
    #expect(
      ProjectMachineSetup.progress(for: ProjectCloneProgress(stage: "copying"))
        == .init(label: "Copying env files…"))
  }

  @Test("pushes a folder with no remote to the pasted URL from its machine, then offers to clone it")
  func publishesThenClones() async throws {
    let source = ProjectSetupFakeClient()
    let target = ProjectSetupFakeClient()
    await source.configure(
      source: ServerProjectSetupSource(
        projectId: sourceProject.id.uuidString, folderPath: "/Users/me/notes", needsInitialCommit: true))
    await target.configure(setupResults: [.success(clonedProject(id: UUID().uuidString))])
    let setup = makeSetup(source: source, target: target)
    var local = sourceProject
    local.repoUrl = nil
    local.repoKey = nil

    await setup.prepare(group: ProjectGroup(solo: local), targetServerId: "studio", preferredSource: nil)
    #expect(setup.plan?.needsRemote == true)
    #expect(setup.plan?.needsInitialCommit == true)
    setup.setRepoUrl("not a url")
    setup.confirm()
    #expect(setup.isRunning == false)
    setup.setRepoUrl(" https://github.com/me/notes.git ")
    setup.confirm()
    try await waitUntil {
      if case let .confirming(plan) = setup.phase { return !plan.needsRemote }
      return false
    }
    #expect(await target.setupRequests.isEmpty)
    setup.confirm()
    try await waitUntil {
      if case .finished = setup.phase { return true }
      return false
    }

    let publishes = await source.publishes
    #expect(publishes.map(\.url) == ["https://github.com/me/notes.git"])
    #expect(publishes.map(\.initialize) == [true])
    #expect(await target.setupRequests.first?.url == "https://github.com/me/notes.git")
  }

  @Test("reads the host and repository name of SSH, SCP and HTTPS remotes")
  func remoteHosts() {
    #expect(GitRemoteURL.repositoryName(of: "git@github.com:acme/widget.git") == "acme/widget")
    #expect(GitRemoteURL.repositoryName(of: "https://gitlab.com/acme/tools/widget") == "acme/tools/widget")
    #expect(GitRemoteURL.host(of: "git@github.com:acme/widget.git") == "github.com")
    #expect(GitRemoteURL.host(of: "ssh://git@GitLab.com/acme/widget.git") == "gitlab.com")
    #expect(GitRemoteURL.host(of: "https://bitbucket.org/acme/widget") == "bitbucket.org")
    #expect(GitRemoteURL.host(of: "/srv/git/widget") == nil)
    #expect(GitRemoteURL.isValid("git@github.com:acme/widget.git"))
    #expect(!GitRemoteURL.isValid("github.com"))
  }
}
