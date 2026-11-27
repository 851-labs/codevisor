import CodevisorClient
import ComposableArchitecture
import Foundation

@Reducer
public struct MachineDesktopSetup {
  public enum Confirmation: Equatable, Sendable {
    case remove, replaceOld, replaceUnmanaged, stopSharing
  }

  enum Attempt: Equatable, Sendable { case look, remove, setup }

  public enum Phase: Equatable, Sendable {
    case asking
    case checking
    case failed(String)
    case needsAdministrator(String)
    case noDesktop(setUpBefore: Bool)
    case ready
    case settingUp(String)
    case updateNeeded
  }

  @ObservableState
  public struct State: Equatable {
    @Presents public var confirmation: ConfirmationDialogState<Confirmation>?
    public var asker: UUID?
    var given = MachineDesktopSetupStep.Given()
    var lastAttempt = Attempt.setup
    public var machineName: String
    public var phase = Phase.checking
    public var status: ServerDesktopStatus?

    public init(machineName: String) {
      self.machineName = machineName
    }

    public var isBusy: Bool {
      if case .settingUp = phase { true } else { false }
    }

    public var terminalCommand: String {
      status?.setupCommand ?? MachineDesktopWords.setupCommand
    }

    public func showsDesktop(sharedByMachine: Bool) -> Bool {
      guard sharedByMachine else { return false }

      switch phase {
      case .checking, .ready, .updateNeeded: return true
      case .failed: return status == nil
      case .asking, .needsAdministrator, .noDesktop, .settingUp: return false
      }
    }

    public var awaitsItsDesktop: Bool { phase == .ready }

    public var removal: Confirmation? {
      guard !isBusy, let status, status.state == .running || status.state == .stopped else { return nil }

      return status.unmanaged == true ? .stopSharing : .remove
    }
  }

  public enum Action {
    case confirmation(PresentationAction<Confirmation>)
    case desktopNeverAppeared
    case askerLeft(UUID)
    case interacted(from: UUID)
    case looked(Result<ServerDesktopStatus, any Error>)
    case machineChanged
    case machineRenamed(String)
    case removeButtonTapped
    case removed(Result<ServerDesktopStatus, any Error>)
    case setUpButtonTapped
    case started(Result<ServerDesktopStatus, any Error>)
    case stepped(Result<ServerDesktopStatus, any Error>)
    case task
    case tryAgainButtonTapped
  }

  enum CancelID { case watching }

  static let pollInterval: Duration = .seconds(2)

  @Dependency(\.continuousClock) var clock
  @Dependency(MachineDesktopClient.self) var desktop

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .confirmation(.presented(let answer)):
        return answered(answer, &state)

      case .confirmation(.dismiss):
        stopAsking(&state)
        return .none

      case .askerLeft(let view):
        guard state.asker == view else { return .none }
        state.asker = nil
        state.confirmation = nil
        stopAsking(&state)
        return .none

      case .desktopNeverAppeared:
        guard state.phase == .ready else { return .none }
        state.lastAttempt = .look
        state.phase = .failed(MachineDesktopWords.notSeen(on: state.machineName))
        return .none

      case .interacted(let site):
        state.asker = site
        return .none

      case .looked(.success(let status)):
        state.status = status
        state.lastAttempt = .setup
        guard state.phase != .asking else { return .none }
        return rest(&state, status)

      case .looked(.failure(let error)):
        guard state.phase == .checking || state.isBusy else { return .none }
        state.lastAttempt = .look
        state.phase = Self.phase(for: error)
        return .none

      case .machineRenamed(let name):
        renamed(name, &state)
        return .none

      case .machineChanged, .task:
        guard !state.isBusy else { return .none }
        return look()

      case .removeButtonTapped:
        return askToRemove(&state)

      case .removed(.success(let status)), .started(.success(let status)):
        state.status = status
        state.lastAttempt = .setup
        state.phase = Self.resting(status, on: state.machineName)
        return .none

      case .removed(.failure(let error)):
        state.lastAttempt = .remove
        state.phase = Self.phase(for: error)
        return .none

      case .started(.failure(let error)), .stepped(.failure(let error)):
        state.lastAttempt = .setup
        state.phase = Self.phase(for: error)
        return .none

      case .setUpButtonTapped:
        return setUp(&state)

      case .tryAgainButtonTapped:
        return tryAgain(&state)

      case .stepped(.success(let status)):
        state.status = status
        return advance(&state)
      }
    }
    .ifLet(\.$confirmation, action: \.confirmation)
  }

  private func stopAsking(_ state: inout State) {
    guard state.phase == .asking, let status = state.status else { return }

    state.phase = Self.resting(status, on: state.machineName)
  }

  private func renamed(_ name: String, _ state: inout State) {
    let wasResting = state.status.map { state.phase == Self.resting($0, on: state.machineName) } ?? false
    state.machineName = name
    guard wasResting, let status = state.status else { return }

    state.phase = Self.resting(status, on: name)
  }

  private func look() -> Effect<Action> {
    .run { [desktop] send in await send(.looked(Result { try await desktop.status() })) }
      .cancellable(id: CancelID.watching, cancelInFlight: true)
  }

  private func askToRemove(_ state: inout State) -> Effect<Action> {
    guard let removal = state.removal else { return .none }

    state.confirmation = MachineDesktopDialogs.dialog(removal, on: state.machineName)
    return .none
  }

  private func setUp(_ state: inout State) -> Effect<Action> {
    guard !state.isBusy else { return .none }

    state.given = .init()
    state.phase = .settingUp(MachineDesktopWords.checking(state.machineName))
    return .merge(.cancel(id: CancelID.watching), step { [desktop] in try await desktop.status() })
  }

  private func tryAgain(_ state: inout State) -> Effect<Action> {
    switch state.lastAttempt {
    case .look:
      state.phase = .checking
      return look()
    case .remove:
      return askToRemove(&state)
    case .setup:
      return setUp(&state)
    }
  }

  private func remove(unsharing: Bool, _ state: inout State) -> Effect<Action> {
    state.phase = .settingUp(unsharing ? MachineDesktopWords.unsharing : MachineDesktopWords.removing)
    return .merge(
      .cancel(id: CancelID.watching),
      .run { [desktop] send in await send(.removed(Result { try await desktop.remove(unsharing) })) })
  }

  private func answered(_ answer: Confirmation, _ state: inout State) -> Effect<Action> {
    switch answer {
    case .remove:
      return remove(unsharing: false, &state)
    case .stopSharing:
      return remove(unsharing: true, &state)
    case .replaceOld:
      state.given.mayReplaceOld = true
      return advance(&state)
    case .replaceUnmanaged:
      state.given.mayReplaceUnmanaged = true
      return advance(&state)
    }
  }

  private func advance(_ state: inout State) -> Effect<Action> {
    guard let status = state.status else { return .none }

    switch MachineDesktopSetupStep.next(after: status, given: state.given, on: state.machineName) {
    case .ask(let question):
      state.phase = .asking
      state.confirmation = MachineDesktopDialogs.dialog(question, on: state.machineName)
      return .none
    case .done:
      state.phase = .ready
      return .none
    case .fail(let sentence):
      state.phase = .failed(sentence)
      return .none
    case .installPackages:
      state.given.askedForPackages = true
      state.phase = .settingUp(MachineDesktopWords.installing)
      return step { [desktop] in try await desktop.installPackages() }
    case .needAdministrator(let sentence):
      state.phase = .needsAdministrator(sentence)
      return .none
    case .replaceOld:
      state.given.askedToReplaceOld = true
      state.phase = .settingUp(MachineDesktopWords.removingOld)
      return step { [desktop] in try await desktop.replaceOld() }
    case .start(let replacingUnmanaged):
      state.phase = .settingUp(MachineDesktopWords.starting)
      return .run { [desktop] send in
        await send(.started(Result { try await desktop.start(replacingUnmanaged) }))
      }
    case .waitForPackages:
      state.phase = .settingUp(MachineDesktopWords.installing)
      return step { [clock, desktop] in
        try await clock.sleep(for: Self.pollInterval)
        return try await desktop.status()
      }
    }
  }

  private func rest(_ state: inout State, _ status: ServerDesktopStatus) -> Effect<Action> {
    guard status.busy != nil else {
      state.phase = Self.resting(status, on: state.machineName)
      return .none
    }

    state.phase = .settingUp(MachineDesktopWords.installing)
    return .run { [clock, desktop] send in
      try await clock.sleep(for: Self.pollInterval)
      await send(.looked(Result { try await desktop.status() }))
    }
    .cancellable(id: CancelID.watching, cancelInFlight: true)
  }

  private func step(_ work: @escaping @Sendable () async throws -> ServerDesktopStatus) -> Effect<Action> {
    .run { send in await send(.stepped(Result { try await work() })) }
  }

  static func resting(_ status: ServerDesktopStatus, on machine: String) -> Phase {
    switch status.state {
    case .none: .noDesktop(setUpBefore: false)
    case .outdated: .noDesktop(setUpBefore: true)
    case .running: .ready
    case .stopped: .failed(MachineDesktopWords.notRunning(status, on: machine))
    }
  }

  static func phase(for error: any Error) -> Phase {
    if case .httpStatus(404, _) = error as? CodevisorServerClientError { return .updateNeeded }

    return .failed(MachineDesktopWords.sentence(from: error))
  }
}
