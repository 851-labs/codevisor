import CodevisorCore
import SwiftUI

public struct MachineAttentionCard: View {
  private let attention: MachineAttention
  private let machineName: String
  private let openSettings: () -> Void

  public init(_ attention: MachineAttention, machineName: String, openSettings: @escaping () -> Void) {
    self.attention = attention
    self.machineName = machineName
    self.openSettings = openSettings
  }

  public var body: some View {
    ContentUnavailableView {
      Label(attention.title(machineName: machineName), systemImage: "desktopcomputer")
    } actions: {
      Button("Open Settings", action: openSettings)
    }
  }
}
