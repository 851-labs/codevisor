import CodevisorClient

@MainActor
public enum ScreenSharingTargetActivity {
  public static func isActive(on machine: ScreenSharingMachine) async -> Bool? {
    guard let target = machine.target else { return nil }
    guard let reply = try? await machine.channel().send(ScreenSharingHostRequests.capabilities(of: machine)) else {
      return nil
    }

    return isActive(reply, target: target)
  }

  public static func isActive(_ reply: ServerScreenSharingReply, target: String) -> Bool? {
    guard reply.version == 1 else { return nil }

    switch reply.status {
    case "available", "busy": return reply.displays.contains { $0.id == target }
    case "unavailable": return false
    default: return nil
    }
  }
}
