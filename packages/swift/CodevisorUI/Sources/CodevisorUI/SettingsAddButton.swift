import SwiftUI

public struct SettingsAddButton: View {
  private let title: String
  private let action: () -> Void

  public init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Label(title, systemImage: "plus")
    }
    .help(title)
  }
}
