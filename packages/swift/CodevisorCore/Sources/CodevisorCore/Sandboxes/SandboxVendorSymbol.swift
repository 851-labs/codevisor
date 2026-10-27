import Foundation

public enum SandboxVendorSymbol {
  public static func name(for vendorId: String) -> String {
    switch vendorId {
    case "tart": "desktopcomputer"
    case "tart-orchard": "server.rack"
    case "e2b": "cube"
    case "modal": "square.stack.3d.up"
    case "vercel": "triangle.fill"
    case "daytona": "sun.max"
    default: "shippingbox"
    }
  }
}
