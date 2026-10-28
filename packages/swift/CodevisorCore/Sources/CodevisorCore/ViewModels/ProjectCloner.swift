import Foundation

@MainActor
struct ProjectCloner {
  typealias Plan = ProjectMachineSetup.Plan
  typealias Failure = ProjectMachineSetup.Failure

  let clientFor: (String) -> any CodevisorServerClienting
  let machineName: (String) -> String

  func clone(
    _ plan: Plan,
    projectId: UUID,
    onEvent: @escaping @MainActor (ProjectSetupEvent) -> Void
  ) async -> Result<Project, Failure> {
    let source: SourceFiles
    do {
      source = try await sourceFiles(plan)
    } catch {
      return .failure(Failure(message: "Couldn't read env files", code: nil, host: nil))
    }
    onEvent(.progress(ProjectCloneProgress(stage: "connecting")))
    return await setUp(plan, projectId: projectId, source: source, onEvent: onEvent)
  }

  func failure(_ plan: Plan, code: String?, serverId: String? = nil) -> Failure {
    let machine = serverId.map(machineName) ?? plan.targetMachineName
    return Failure(
      message: ProjectMachineSetup.message(plan: plan, code: code, machine: machine), code: code, host: plan.host,
      serverId: serverId)
  }

  private struct SourceFiles {
    var homeRelativePath: String?
    var envFiles: [ServerProjectEnvFileContent] = []
  }

  private func sourceFiles(_ plan: Plan) async throws -> SourceFiles {
    var files = SourceFiles(homeRelativePath: plan.homeRelativePath)
    guard plan.copiesEnvFiles, let sourceServerId = plan.sourceServerId,
      let sourceProjectId = plan.sourceProjectId
    else { return files }

    let source = clientFor(sourceServerId)
    let details = try await source.projectSetupSource(projectId: sourceProjectId)
    files.homeRelativePath = plan.homeRelativePath ?? details.homeRelativePath
    let paths = details.envFiles.map(\.path)
    if !paths.isEmpty {
      files.envFiles = try await source.readProjectEnvFiles(projectId: sourceProjectId, paths: paths)
    }
    return files
  }

  private func setUp(
    _ plan: Plan,
    projectId: UUID,
    source: SourceFiles,
    onEvent: @escaping @MainActor (ProjectSetupEvent) -> Void
  ) async -> Result<Project, Failure> {
    let target = clientFor(plan.targetServerId)
    let (outcomes, outcomeSink) = AsyncStream.makeStream(of: ProjectCloneOutcome.self)
    let tail = ServerSetupEventTail.follow(
      target, kinds: ["project.setup", "project.created"], subjectId: projectId.uuidString)
    let follow = Task {
      for await item in tail {
        guard case let .event(envelope) = item else { continue }
        if let event = ProjectSetupEvent.from(envelope, projectId: projectId.uuidString) { onEvent(event) }
        if let outcome = ProjectCloneOutcome.from(envelope, projectId: projectId.uuidString) {
          outcomeSink.yield(outcome)
        }
      }
      outcomeSink.finish()
    }
    defer { follow.cancel() }
    do {
      let created = try await target.setUpProjectFromGit(request(plan, projectId: projectId, source: source))
      return .success(try created.project(serverId: plan.targetServerId))
    } catch let error as CodevisorServerClientError {
      return .failure(failure(plan, code: serverErrorCode(error)))
    } catch {
      return await outcome(of: outcomes, plan: plan, projectId: projectId)
    }
  }

  private func request(_ plan: Plan, projectId: UUID, source: SourceFiles) -> ServerProjectSetupRequest {
    ServerProjectSetupRequest(
      id: projectId,
      url: plan.repoUrl,
      name: plan.projectName,
      homeRelativePath: source.homeRelativePath,
      envFiles: source.envFiles.isEmpty ? nil : source.envFiles,
      worktreeBase: plan.worktreeBase,
      defaultRunLocation: plan.defaultRunLocation
    )
  }

  private func outcome(
    of outcomes: AsyncStream<ProjectCloneOutcome>,
    plan: Plan,
    projectId: UUID
  ) async -> Result<Project, Failure> {
    for await outcome in outcomes {
      switch outcome {
      case let .failed(_, code):
        return .failure(failure(plan, code: code))
      case .created:
        return await listedProject(plan: plan, projectId: projectId)
      }
    }
    return .failure(failure(plan, code: nil))
  }

  private func listedProject(plan: Plan, projectId: UUID) async -> Result<Project, Failure> {
    let listed = try? await clientFor(plan.targetServerId).listProjects().first {
      $0.id.caseInsensitiveCompare(projectId.uuidString) == .orderedSame
    }
    guard let project = try? listed?.project(serverId: plan.targetServerId) else {
      return .failure(failure(plan, code: nil))
    }
    return .success(project)
  }
}
