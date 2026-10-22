struct ComputerUseScrollWheels {
  let vertical: Int32
  let horizontal: Int32

  init(direction: String, magnitude: Int32) {
    switch direction {
    case "up": self.init(vertical: magnitude, horizontal: 0)
    case "down": self.init(vertical: -magnitude, horizontal: 0)
    case "left": self.init(vertical: 0, horizontal: magnitude)
    case "right": self.init(vertical: 0, horizontal: -magnitude)
    default: self.init(vertical: 0, horizontal: 0)
    }
  }

  private init(vertical: Int32, horizontal: Int32) {
    self.vertical = vertical
    self.horizontal = horizontal
  }
}
