import Foundation

public struct ServerBotMascot: Codable, Hashable, Sendable {
  public var color: String
  public var hat: String
  public var eyewear: String

  public init(color: String, hat: String, eyewear: String) {
    self.color = color
    self.hat = hat
    self.eyewear = eyewear
  }

  var imagePath: String {
    var query = URLComponents()
    query.queryItems = [
      URLQueryItem(name: "color", value: color),
      URLQueryItem(name: "hat", value: hat),
      URLQueryItem(name: "eyewear", value: eyewear),
    ]
    return "/v1/bot-mascots/image?\(query.percentEncodedQuery ?? "")"
  }
}
