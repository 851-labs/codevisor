import Foundation

extension ProjectMachineSetup {
  static func progress(for clone: ProjectCloneProgress) -> SetupProgress {
    let fraction = clone.percent.map { $0 / 100 }
    switch clone.stage {
    case "connecting":
      return SetupProgress(label: "Connecting…")
    case "copying":
      return SetupProgress(label: "Copying env files…")
    case "counting":
      return SetupProgress(label: "Counting objects…", fraction: fraction, detail: counts(clone))
    case "receiving":
      return SetupProgress(
        label: "Receiving objects…", fraction: fraction,
        detail: transfer(clone) ?? counts(clone).map { "\($0) objects" })
    case "resolving":
      return SetupProgress(label: "Resolving deltas…", fraction: fraction, detail: counts(clone))
    case "checkout":
      return SetupProgress(label: "Checking out files…", fraction: fraction, detail: counts(clone))
    default:
      return SetupProgress(label: "Cloning…", fraction: fraction)
    }
  }

  fileprivate static func counts(_ clone: ProjectCloneProgress) -> String? {
    guard let completed = clone.completed, let total = clone.total else { return nil }
    return "\(completed.formatted()) of \(total.formatted())"
  }

  fileprivate static func transfer(_ clone: ProjectCloneProgress) -> String? {
    guard let bytes = clone.bytes else { return nil }
    let size = bytes.formatted(.byteCount(style: .file))
    guard let rate = clone.bytesPerSecond else { return size }
    return "\(size) · \(rate.formatted(.byteCount(style: .file)))/s"
  }

  static func message(plan: Plan, code: String?, machine: String) -> String {
    let provider = plan.provider?.displayName ?? "remote"
    switch code {
    case "auth_failed": return "Not signed in to \(provider)"
    case "repo_not_found":
      return "\(plan.repositoryName) doesn't exist, or \(machine)'s \(provider) account can't see it."
    case "network": return "Can't reach \(provider)"
    case "disk_full": return "Disk full"
    case "in_progress": return "Already setting up"
    case "already_exists": return "No free folder"
    case "invalid_url": return "Not a repository URL"
    case "push_rejected": return "Remote already has commits"
    case "identity_missing": return "Set your git name and email"
    default: return plan.needsRemote ? "Push failed" : "Clone failed"
    }
  }
}
