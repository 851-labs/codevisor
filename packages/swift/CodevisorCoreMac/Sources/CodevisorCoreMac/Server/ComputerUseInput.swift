import CoreGraphics

/// Agent events own their button/modifier state instead of sharing the human's
/// HID state. Physical input stays enabled so foreground control can be revoked.
func computerUseEventSource() throws -> CGEventSource {
  guard let source = CGEventSource(stateID: .privateState) else {
    throw BridgeError("Unable to create Computer Use event source")
  }
  source.userData = ComputerUseForeground.eventTag
  source.localEventsSuppressionInterval = 0
  let permitted: CGEventFilterMask = [
    .permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents,
  ]
  source.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateSuppressionInterval)
  source.setLocalEventsFilterDuringSuppressionState(permitted, state: .eventSuppressionStateRemoteMouseDrag)
  return source
}
