nonisolated enum GitInstallProgress: Equatable {
  case notStarted
  case opening
  case waiting
  case failed(String)
}
