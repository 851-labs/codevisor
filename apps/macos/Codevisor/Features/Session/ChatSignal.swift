import CodevisorCore

struct ChatSignal<Value: Equatable>: Equatable {
  let chat: ObjectIdentifier
  let value: Value

  init(_ value: Value, of controller: SessionController) {
    chat = ObjectIdentifier(controller)
    self.value = value
  }

  func isSameChat(as other: Self) -> Bool { chat == other.chat }
}
