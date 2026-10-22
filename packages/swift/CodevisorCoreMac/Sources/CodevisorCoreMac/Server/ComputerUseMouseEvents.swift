import CoreGraphics

struct ComputerUseMouseEvents {
  let down: CGEventType
  let up: CGEventType
  let button: CGMouseButton

  init(button name: String) {
    switch name {
    case "right": self.init(down: .rightMouseDown, up: .rightMouseUp, button: .right)
    case "middle": self.init(down: .otherMouseDown, up: .otherMouseUp, button: .center)
    default: self.init(down: .leftMouseDown, up: .leftMouseUp, button: .left)
    }
  }

  private init(down: CGEventType, up: CGEventType, button: CGMouseButton) {
    self.down = down
    self.up = up
    self.button = button
  }
}
