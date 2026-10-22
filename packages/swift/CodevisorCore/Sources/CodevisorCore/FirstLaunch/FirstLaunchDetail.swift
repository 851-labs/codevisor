import Foundation

public enum FirstLaunchDetail {
  public static func candidates(harnesses names: [String]) -> [String] {
    guard !names.isEmpty else { return [] }
    let shortened = (1..<names.count).reversed().map { shown in
      "\(names.prefix(shown).joined(separator: ", ")) +\(names.count - shown)"
    }
    return [ListFormatter.localizedString(byJoining: names)] + shortened + [harnessCount(names.count)]
  }

  public static func candidates(projects count: Int) -> [String] {
    switch count {
    case 0: []
    case 1: ["1 project"]
    default: ["\(count) projects"]
    }
  }

  private static func harnessCount(_ count: Int) -> String {
    count == 1 ? "1 harness" : "\(count) harnesses"
  }
}
