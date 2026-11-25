struct CachedFileKey: Hashable, Sendable {
  let machineId: String
  let fileId: String

  var bindings: [ClientDatabase.Binding] { [.text(machineId), .text(fileId)] }
}
