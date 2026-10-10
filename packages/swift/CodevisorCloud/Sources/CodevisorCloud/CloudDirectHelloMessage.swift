struct CloudDirectHelloMessage: Encodable {
  struct Device: Encodable {
    var deviceId: String
    var kind = "app"
    var name: String
    var os: String
    var appVersion: String?
    var publicKey: String
  }

  var t = "hello"
  var protocolVersion = CloudDirectConnection.protocolVersion
  var device: Device

  enum CodingKeys: String, CodingKey {
    case t
    case protocolVersion = "protocol"
    case device
  }
}
