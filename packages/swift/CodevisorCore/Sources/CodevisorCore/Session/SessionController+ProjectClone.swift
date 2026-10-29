import Foundation

extension SessionController {
  public var projectCloneFailureMessage: String? {
    guard case let .failed(message) = status, projectCloneFailure?.message == message else { return nil }
    return message
  }

  public var projectCloneFailureOffersSignIn: Bool {
    projectCloneFailure?.canSignIn == true
  }

  public func retryProjectClone() {
    sends.retryFailures()
  }

  public func signInForProjectClone() {
    guard let projectClone, let failure = projectCloneFailure else { return }

    projectClone.setup.present(projectClone.plan, failure: failure)
    if !failure.needsSignIn { projectClone.setup.signIn() }
  }

  func provisionalCloneProject() -> Project? {
    guard let projectClone, projectClone.plan.targetServerId == project.serverId else { return nil }

    let provisional = projectClone.provisionalProject
    projectClone.projectList?.showCloningProject(provisional)
    return provisional
  }

  func cloneRequestedProject(showsSetupPhases: Bool) async -> String? {
    guard let request = projectClone, request.projectId == project.id else { return nil }

    projectCloneFailure = nil
    let phase = cloneSetupPhase
    if showsSetupPhases { beginSetupPhase(phase) }
    status = .connecting("Cloning \(request.plan.projectName)…")
    let log = ProjectCloneLog()
    let result = await request.setup.cloner.clone(request.plan, projectId: request.projectId) { [weak self] event in
      guard let line = log.line(for: event) else { return }
      self?.mutateSetupPhase(id: phase.id) { $0.appendLog(stream: line.stream, line: line.text) }
    }
    switch result {
    case let .success(cloned):
      adoptClonedProject(cloned, phaseId: phase.id)
      return nil
    case let .failure(failure):
      mutateSetupPhase(id: phase.id) { $0.fail(message: failure.message) }
      failClone(request, failure: failure)
      return failure.message
    }
  }

  private var cloneSetupPhase: SessionSetupPhase {
    wantsNewWorktree ? .worktree() : .projectSetup()
  }

  private func adoptClonedProject(_ cloned: Project, phaseId: String) {
    if phaseId != SessionSetupPhase.worktreePhaseId {
      mutateSetupPhase(id: phaseId) { $0.succeed() }
    }
    projectClone = nil
    project = cloned
    if var session = serverSession {
      session.projectId = cloned.id
      serverSession = session
    }
    status = .idle
    onProjectCloned?(cloned)
  }

  private func failClone(_ request: ProjectCloneRequest, failure: ProjectMachineSetup.Failure) {
    projectCloneFailure = failure
    request.setup.retryHandler = { [weak self] in self?.retryProjectClone() }
    request.setup.present(request.plan, failure: failure)
  }
}
