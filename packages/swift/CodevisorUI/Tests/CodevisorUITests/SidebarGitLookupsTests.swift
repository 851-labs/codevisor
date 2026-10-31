import CodevisorCore
import CodevisorTestSupport
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
@Suite("Sidebar git lookups", .timeLimit(.minutes(1)))
struct SidebarGitLookupsTests {
  private let pullRequest = ServerGitPullRequest(
    number: 7, title: "Badge", state: .open, isDraft: false,
    url: URL(string: "https://github.com/acme/app/pull/7")!)

  private func workspace(_ path: String, git: ServerWorkspaceGit?) -> Workspace {
    var workspace = Workspace(
      name: path, rootDirectory: path, serverId: "local", projectId: UUID(),
      centerTree: .leaf(.centerInitialWithoutChat()), isServerSynced: true)
    workspace.git = git
    return workspace
  }

  @Test("A workspace the server reports git for answers from its record, even with no branch")
  func serverGitAnswers() async {
    let lookups = SidebarGitLookups()
    let reported = workspace("/repo/a", git: ServerWorkspaceGit(branch: "feature", pullRequest: pullRequest))
    let noBranch = workspace("/repo/b", git: ServerWorkspaceGit(branch: nil, pullRequest: nil))
    var polled = noBranch
    polled.git = nil
    let client = CodevisorServerClient(config: CodevisorServerConfig(requestTransport: GitRecordingTransport()))
    lookups.refresh(
      active: [polled], archived: [], listedIds: [polled.id], details: [.branch, .pullRequest],
      client: { _ in client })
    await awaitObserved { lookups.branch(for: polled) != nil && lookups.pullRequest(for: polled) != nil }

    #expect(lookups.branch(for: reported) == "feature")
    #expect(lookups.pullRequest(for: reported) == pullRequest)
    #expect(lookups.branch(for: noBranch) == nil)
    #expect(lookups.pullRequest(for: noBranch) == nil)
  }

  @Test("A detached HEAD shows its commit instead of no branch")
  func detachedHeadShowsCommit() {
    let lookups = SidebarGitLookups()
    let detached = workspace(
      "/repo/a", git: ServerWorkspaceGit(branch: nil, detachedHead: "e6a622bef", pullRequest: nil))

    #expect(lookups.branch(for: detached) == "e6a622bef (detached)")
  }

  @Test("Only workspaces from a server that doesn't report git are looked up")
  func onlyLegacyWorkspacesPoll() async throws {
    let lookups = SidebarGitLookups()
    let transport = GitRecordingTransport()
    let client = CodevisorServerClient(config: CodevisorServerConfig(requestTransport: transport))
    let reported = workspace("/repo/reported", git: ServerWorkspaceGit(branch: "feature", pullRequest: nil))
    let legacy = workspace("/repo/legacy", git: nil)

    lookups.refresh(
      active: [reported, legacy], archived: [], listedIds: [reported.id, legacy.id],
      details: [.branch, .pullRequest], client: { _ in client })
    await awaitObserved { lookups.branch(for: legacy) != nil && lookups.pullRequest(for: legacy) != nil }

    #expect(transport.directories == ["/repo/legacy", "/repo/legacy"])
    #expect(lookups.branch(for: legacy) == "legacy-branch")
    #expect(lookups.branch(for: reported) == "feature")
  }
}

private final class GitRecordingTransport: ServerRequestTransport, Sendable {
  private let requested = Mutex<[String]>([])

  var directories: [String] { requested.withLock { $0.sorted() } }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "path" }?.value
    requested.withLock { $0.append(path ?? url.path) }
    let body =
      url.path.hasSuffix("/refs")
      ? #"{"currentBranch":"legacy-branch","defaultBase":null,"branches":[]}"#
      : #"{"pullRequest":{"number":1,"title":"Legacy","state":"open","isDraft":false,"url":"https://example.com/1","checks":"none"}}"#
    let response = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
    return (Data(body.utf8), response)
  }

  func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    throw URLError(.unsupportedURL)
  }

  func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.unsupportedURL)
  }
}
