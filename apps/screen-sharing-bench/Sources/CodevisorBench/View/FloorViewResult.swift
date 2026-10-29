struct FloorViewResult: Encodable {
  let role = "floor-viewer"
  let port: UInt16
  let presentedVersions: Int
  let latestVersion: Int
  let lastError: String?

  init(_ source: FloorSource) {
    port = source.port
    presentedVersions = source.presentedVersions
    latestVersion = source.latestVersion
    lastError = source.lastError
  }
}
