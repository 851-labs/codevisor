import SwiftUI

public struct HarnessCodeStep: Identifiable {
  public let id: String
  public let harnessName: String
  public let url: String?
  public let submit: (String) async -> String?
  public let cancel: () -> Void
}

public struct HarnessCodeStepView {
  let make: (HarnessCodeStep) -> AnyView

  public init<Content: View>(@ViewBuilder _ make: @escaping (HarnessCodeStep) -> Content) {
    self.make = { AnyView(make($0)) }
  }
}

extension EnvironmentValues {
  @Entry public var harnessCodeStepView: HarnessCodeStepView?
}
