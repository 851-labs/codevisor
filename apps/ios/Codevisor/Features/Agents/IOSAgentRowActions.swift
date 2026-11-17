struct IOSAgentRowActions {
  let open: () -> Void
  let setUnread: (Bool) -> Void
  var rename: (() -> Void)? = nil
  var archive: (() -> Void)? = nil
}
