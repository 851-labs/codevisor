import Dispatch

public enum ScreenSharingVCPLab {
  public enum QPCap: Int, Sendable {
    case flip = 0
    case steady = 1
    case restore = 2
    case settle = 3
    case keep = 4
  }

  public nonisolated(unsafe) static var qpCap = QPCap.flip
  static let restoreQueue = DispatchQueue(label: "codevisor.screen-sharing.v2.vcp-lab", qos: .userInitiated)
}
