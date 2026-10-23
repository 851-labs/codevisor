import Foundation

public enum FirstLaunchDetail {
  public static func candidates(for step: FirstLaunchStep, names: [String]) -> [String] {
    guard !names.isEmpty, let count = countText(for: step, count: names.count) else { return [] }
    let shortened = (1..<names.count).reversed().map { shown in
      "\(names.prefix(shown).joined(separator: ", ")) +\(names.count - shown)"
    }
    return [ListFormatter.localizedString(byJoining: names)] + shortened + [count]
  }

  private static func countText(for step: FirstLaunchStep, count: Int) -> String? {
    switch step {
    case .harnesses: count == 1 ? "1 harness" : "\(count) harnesses"
    case .projects: count == 1 ? "1 project" : "\(count) projects"
    case .server, .models: nil
    }
  }
}
