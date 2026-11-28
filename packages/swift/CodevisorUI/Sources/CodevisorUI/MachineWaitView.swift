import SwiftUI

public struct MachineWaitView: View {
  public static let revealDelay: Duration = .milliseconds(500)

  @State private var isRevealed = false

  public init() {}

  public var body: some View {
    ZStack {
      Color.clear
      if isRevealed {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      guard (try? await Task.sleep(for: Self.revealDelay)) != nil else { return }
      isRevealed = true
    }
  }
}
