import Foundation

extension Autocomplete {
  enum Strings {
    static func text(_ key: String) -> String { Bundle.module.localizedString(forKey: key, value: nil, table: nil) }
    static func resultCount(_ count: Int) -> String { String(localized: "\(count) results", bundle: .module) }
    static func position(_ index: Int, count: Int) -> String {
      String(localized: "\(index) of \(count)", bundle: .module)
    }
  }
}
