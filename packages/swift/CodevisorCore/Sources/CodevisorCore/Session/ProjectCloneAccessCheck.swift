import Foundation
import Observation

@MainActor
@Observable
public final class ProjectCloneAccessCheck {
  public typealias Plan = ProjectMachineSetup.Plan

  private var checkingPlan: Plan?
  @ObservationIgnored private var verifiedPlan: Plan?

  public init() {}

  public var isChecking: Bool {
    checkingPlan != nil
  }

  public var label: String? {
    checkingPlan.map { "Checking access to \($0.repositoryName)…" }
  }

  public func isVerified(_ plan: Plan) -> Bool {
    verifiedPlan == plan
  }

  public func check(_ plan: Plan, failuresOn setup: ProjectMachineSetup, resubmit: @escaping () -> Void) {
    guard !isChecking else { return }

    checkingPlan = plan
    Task { await finishCheck(plan, failuresOn: setup, resubmit: resubmit) }
  }

  private func finishCheck(_ plan: Plan, failuresOn setup: ProjectMachineSetup, resubmit: @escaping () -> Void) async {
    let failure = await setup.cloneAccessFailure(plan)
    checkingPlan = nil
    if let failure { return present(failure, of: plan, on: setup, resubmit: resubmit) }

    verifiedPlan = plan
    resubmit()
  }

  private func present(
    _ failure: ProjectMachineSetup.Failure,
    of plan: Plan,
    on setup: ProjectMachineSetup,
    resubmit: @escaping () -> Void
  ) {
    setup.retryHandler = resubmit
    setup.present(plan, failure: failure)
  }
}
