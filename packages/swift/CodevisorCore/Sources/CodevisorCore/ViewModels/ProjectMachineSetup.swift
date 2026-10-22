import Foundation
import Observation

@MainActor
@Observable
public final class ProjectMachineSetup {
  public struct Plan: Equatable, Sendable {
    public let projectName: String
    public var repoUrl: String
    public var needsRemote: Bool
    public var needsInitialCommit: Bool
    public let targetServerId: String
    public let targetMachineName: String
    public let sourceServerId: String?
    public let sourceMachineName: String?
    public let sourceProjectId: UUID?
    public let homeRelativePath: String?
    public let worktreeBase: ProjectWorktreeBase?
    public let defaultRunLocation: ProjectRunLocation?
    public var copiesEnvFiles: Bool

    public init(
      projectName: String,
      repoUrl: String,
      needsRemote: Bool = false,
      needsInitialCommit: Bool = false,
      targetServerId: String,
      targetMachineName: String,
      sourceServerId: String? = nil,
      sourceMachineName: String? = nil,
      sourceProjectId: UUID? = nil,
      homeRelativePath: String? = nil,
      worktreeBase: ProjectWorktreeBase? = nil,
      defaultRunLocation: ProjectRunLocation? = nil,
      copiesEnvFiles: Bool = true
    ) {
      self.projectName = projectName
      self.repoUrl = repoUrl
      self.needsRemote = needsRemote
      self.needsInitialCommit = needsInitialCommit
      self.targetServerId = targetServerId
      self.targetMachineName = targetMachineName
      self.sourceServerId = sourceServerId
      self.sourceMachineName = sourceMachineName
      self.sourceProjectId = sourceProjectId
      self.homeRelativePath = homeRelativePath
      self.worktreeBase = worktreeBase
      self.defaultRunLocation = defaultRunLocation
      self.copiesEnvFiles = copiesEnvFiles
    }

    public var host: String? { GitRemoteURL.host(of: repoUrl) }
    public var repositoryName: String { GitRemoteURL.repositoryName(of: repoUrl) }
    public var provider: GitHostProvider? { host.flatMap(GitHostProvider.init(host:)) }
    public var isReady: Bool { !needsRemote || GitRemoteURL.isValid(repoUrl) }
  }

  public struct Failure: Equatable, Sendable {
    public let message: String
    public let code: String?
    public let host: String?
    public var serverId: String?

    public var provider: GitHostProvider? { host.flatMap(GitHostProvider.init(host:)) }
    public var isMissingRepository: Bool { code == "repo_not_found" }
    public var needsSignIn: Bool { canSignIn && code == "auth_failed" }
    public var needsHostSignIn: Bool { !canSignIn && code == "auth_failed" }
    public var canSignIn: Bool {
      guard provider?.supportsSignIn == true else { return false }
      return code == "auth_failed" || isMissingRepository
    }
  }

  public struct SetupProgress: Equatable, Sendable {
    public var label: String
    public var fraction: Double?
    public var detail: String?

    public init(label: String, fraction: Double? = nil, detail: String? = nil) {
      self.label = label
      self.fraction = fraction
      self.detail = detail
    }
  }

  public enum Phase: Equatable {
    case idle
    case preparing(Plan)
    case unavailable(projectName: String, machineName: String)
    case confirming(Plan)
    case running(Plan)
    case failed(Plan, Failure)
    case signingIn(Plan, GitSignInModel)
    case finished(Project)

    public static func == (left: Phase, right: Phase) -> Bool {
      switch (left, right) {
      case (.idle, .idle): true
      case let (.preparing(a), .preparing(b)): a == b
      case let (.unavailable(a, x), .unavailable(b, y)): a == b && x == y
      case let (.confirming(a), .confirming(b)): a == b
      case let (.running(a), .running(b)): a == b
      case let (.failed(a, x), .failed(b, y)): a == b && x == y
      case let (.signingIn(a, x), .signingIn(b, y)): a == b && x === y
      case let (.finished(a), .finished(b)): a == b
      default: false
      }
    }
  }

  public private(set) var phase: Phase = .idle
  public private(set) var progress = SetupProgress(label: "")
  @ObservationIgnored public var onFinished: ((Project) -> Void)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var activeProjectId: UUID?

  @ObservationIgnored private let clientFor: (String) -> any CodevisorServerClienting
  @ObservationIgnored private let machineName: (String) -> String
  @ObservationIgnored private let isReachable: (String) -> Bool
  @ObservationIgnored private let adopt: (Project) -> Void

  public init(
    clientFor: @escaping (String) -> any CodevisorServerClienting,
    machineName: @escaping (String) -> String,
    isReachable: @escaping (String) -> Bool,
    adopt: @escaping (Project) -> Void
  ) {
    self.clientFor = clientFor
    self.machineName = machineName
    self.isReachable = isReachable
    self.adopt = adopt
  }

  public var isPresented: Bool {
    if case .idle = phase { return false }
    return true
  }

  public var isRunning: Bool {
    if case .running = phase { return true }
    return false
  }

  public var isPushing: Bool {
    if case let .running(plan) = phase { return plan.needsRemote }
    return false
  }

  public var offersSignIn: Bool {
    if case let .failed(_, failure) = phase { return failure.canSignIn }
    return false
  }

  public var plan: Plan? {
    switch phase {
    case let .preparing(plan), let .confirming(plan), let .running(plan), let .failed(plan, _),
      let .signingIn(plan, _):
      plan
    default: nil
    }
  }

  public func prepare(group: ProjectGroup, targetServerId: String, preferredSource: Project?) async {
    guard !isPresented else { return }
    let target = machineName(targetServerId)
    let repoUrl = group.members.lazy.compactMap(\.repoUrl).first
    let candidates = group.members.filter { $0.serverId != targetServerId && isReachable($0.serverId) }
    let source =
      preferredSource.flatMap { preferred in candidates.first { $0 == preferred } }
      ?? candidates.first { $0.isGitRepository }
      ?? candidates.first
    guard repoUrl != nil || source != nil else {
      phase = .unavailable(projectName: group.name, machineName: target)
      return
    }
    let pending = Plan(
      projectName: group.name,
      repoUrl: repoUrl ?? "",
      needsRemote: repoUrl == nil,
      targetServerId: targetServerId,
      targetMachineName: target,
      sourceServerId: source?.serverId,
      sourceMachineName: source.map { machineName($0.serverId) },
      sourceProjectId: source?.id,
      worktreeBase: group.members.filter(\.isGitRepository).lazy.compactMap(\.worktreeBase).first,
      defaultRunLocation: group.defaultRunLocation
    )
    phase = .preparing(pending)
    var details: ServerProjectSetupSource?
    if let source {
      details = try? await clientFor(source.serverId).projectSetupSource(projectId: source.id)
    }
    guard case let .preparing(current) = phase else { return }
    phase = .confirming(
      Plan(
        projectName: current.projectName,
        repoUrl: current.repoUrl,
        needsRemote: current.needsRemote,
        needsInitialCommit: current.needsRemote && details?.needsInitialCommit == true,
        targetServerId: targetServerId,
        targetMachineName: target,
        sourceServerId: current.sourceServerId,
        sourceMachineName: current.sourceMachineName,
        sourceProjectId: current.sourceProjectId,
        homeRelativePath: details?.homeRelativePath,
        worktreeBase: current.worktreeBase,
        defaultRunLocation: current.defaultRunLocation,
        copiesEnvFiles: current.copiesEnvFiles
      ))
  }

  public func setCopiesEnvFiles(_ copies: Bool) {
    switch phase {
    case var .preparing(plan):
      plan.copiesEnvFiles = copies
      phase = .preparing(plan)
    case var .confirming(plan):
      plan.copiesEnvFiles = copies
      phase = .confirming(plan)
    default:
      break
    }
  }

  public func setRepoUrl(_ url: String) {
    switch phase {
    case var .confirming(plan) where plan.needsRemote, var .failed(plan, _) where plan.needsRemote:
      plan.repoUrl = url
      phase = .confirming(plan)
    default:
      break
    }
  }

  public func confirm() {
    guard case let .confirming(plan) = phase, plan.isReady else { return }
    start(plan)
  }

  public func retry() {
    switch phase {
    case let .failed(plan, _), let .signingIn(plan, _): start(plan)
    default: break
    }
  }

  public func signIn() {
    guard case let .failed(plan, failure) = phase, failure.canSignIn, let provider = failure.provider
    else { return }
    let serverId = failure.serverId ?? plan.targetServerId
    let model = GitSignInModel(
      client: clientFor(serverId),
      machineName: machineName(serverId),
      suggestedHost: failure.host
    )
    model.onSignedIn = { [weak self] _ in self?.retry() }
    phase = .signingIn(plan, model)
    model.signIn(with: provider)
  }

  public func cancel() {
    switch phase {
    case let .running(plan):
      task?.cancel()
      task = nil
      if let projectId = activeProjectId {
        let client = clientFor(plan.targetServerId)
        Task { try? await client.cancelProjectSetup(id: projectId) }
      }
      activeProjectId = nil
    case let .signingIn(_, model):
      model.cancel()
    default:
      break
    }
    phase = .idle
  }

  public func close() {
    if case .finished = phase { phase = .idle }
  }

  private func start(_ plan: Plan) {
    task?.cancel()
    let label =
      if plan.needsRemote {
        "Pushing to \(plan.provider?.displayName ?? "remote")…"
      } else if plan.copiesEnvFiles && plan.sourceServerId != nil {
        "Reading env files…"
      } else { "Connecting…" }
    progress = SetupProgress(label: label)
    phase = .running(plan)
    task = Task { [weak self] in
      await self?.run(plan)
    }
  }

  private func run(_ plan: Plan) async {
    if plan.needsRemote {
      await publishRemote(plan)
      return
    }
    var envFiles: [ServerProjectEnvFileContent] = []
    if plan.copiesEnvFiles, let sourceServerId = plan.sourceServerId,
      let sourceProjectId = plan.sourceProjectId
    {
      do {
        let source = clientFor(sourceServerId)
        let paths = try await source.projectSetupSource(projectId: sourceProjectId).envFiles.map(\.path)
        if !paths.isEmpty {
          envFiles = try await source.readProjectEnvFiles(projectId: sourceProjectId, paths: paths)
        }
      } catch {
        guard !Task.isCancelled else { return }
        phase = .failed(
          plan,
          Failure(
            message: "Couldn't read env files",
            code: nil,
            host: nil
          ))
        return
      }
    }
    let projectId = UUID()
    activeProjectId = projectId
    progress = SetupProgress(label: "Connecting…")
    let target = clientFor(plan.targetServerId)
    let (outcomes, outcomeSink) = AsyncStream.makeStream(of: ProjectCloneOutcome.self)
    let tail = ServerSetupEventTail.follow(
      target, kinds: ["project.setup", "project.created"], subjectId: projectId.uuidString)
    let follow = Task {
      for await item in tail {
        guard case let .event(envelope) = item else { continue }
        if case let .progress(clone) = ProjectSetupEvent.from(envelope, projectId: projectId.uuidString) {
          progress = Self.progress(for: clone)
        }
        if let outcome = ProjectCloneOutcome.from(envelope, projectId: projectId.uuidString) {
          outcomeSink.yield(outcome)
        }
      }
      outcomeSink.finish()
    }
    defer {
      follow.cancel()
      activeProjectId = nil
    }
    do {
      let created = try await target.setUpProjectFromGit(
        ServerProjectSetupRequest(
          id: projectId,
          url: plan.repoUrl,
          name: plan.projectName,
          homeRelativePath: plan.homeRelativePath,
          envFiles: envFiles.isEmpty ? nil : envFiles,
          worktreeBase: plan.worktreeBase,
          defaultRunLocation: plan.defaultRunLocation
        ))
      guard !Task.isCancelled else { return }
      finish(try created.project(serverId: plan.targetServerId))
    } catch let error as CodevisorServerClientError {
      guard !Task.isCancelled else { return }
      fail(plan, code: serverErrorCode(error))
    } catch {
      guard !Task.isCancelled else { return }
      for await outcome in outcomes {
        switch outcome {
        case let .failed(_, code):
          fail(plan, code: code)
        case .created:
          let listed = try? await target.listProjects().first {
            $0.id.caseInsensitiveCompare(projectId.uuidString) == .orderedSame
          }
          if let project = try? listed?.project(serverId: plan.targetServerId) {
            finish(project)
          } else {
            fail(plan, code: nil)
          }
        }
        return
      }
      fail(plan, code: nil)
    }
  }

  private func publishRemote(_ plan: Plan) async {
    guard let sourceServerId = plan.sourceServerId, let sourceProjectId = plan.sourceProjectId else {
      fail(plan, code: nil)
      return
    }
    let url = plan.repoUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      _ = try await clientFor(sourceServerId).publishProjectRemote(
        projectId: sourceProjectId, url: url, initialize: plan.needsInitialCommit)
    } catch {
      guard !Task.isCancelled else { return }
      fail(plan, code: serverErrorCode(error), serverId: sourceServerId)
      return
    }
    guard !Task.isCancelled else { return }
    var published = plan
    published.repoUrl = url
    published.needsRemote = false
    published.needsInitialCommit = false
    phase = .confirming(published)
  }

  private func finish(_ project: Project) {
    progress = SetupProgress(label: "Starting chat…", fraction: 1)
    adopt(project)
    phase = .finished(project)
    onFinished?(project)
  }

  private func fail(_ plan: Plan, code: String?, serverId: String? = nil) {
    if code == "cancelled" {
      phase = .idle
      return
    }
    let machine = serverId.map(machineName) ?? plan.targetMachineName
    let failure = Failure(
      message: Self.message(plan: plan, code: code, machine: machine), code: code, host: plan.host,
      serverId: serverId)
    phase = .failed(plan, failure)
    if failure.needsSignIn { signIn() }
  }
}
