import Foundation

nonisolated struct ChromiumTargetInfo: Sendable {
  var targetId: String
  var title: String
  var url: String
  var openerId: String?
  var json: [String: Any] {
    var json: [String: Any] = ["targetId": targetId, "type": "page", "title": title, "url": url, "attached": false]
    json["openerId"] = openerId
    return json
  }
}
