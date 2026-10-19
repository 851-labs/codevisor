import Foundation

enum VNCClipboardRelayMessage: Equatable {
  case host(richContent: Bool)
  case transfer(ScreenSharingClipboardMessage)

  static func decode(_ text: String) -> Self? {
    let data = Data(text.utf8)
    guard data.count <= ScreenSharingClipboardMessage.maximumBytes + 1024,
      let header = try? JSONDecoder().decode(Header.self, from: data)
    else { return nil }
    switch header.type {
    case "clipboard-host":
      return (try? JSONDecoder().decode(Host.self, from: data)).map { .host(richContent: $0.richContent) }
    case "clipboard":
      guard let frame = try? JSONDecoder().decode(Frame.self, from: data), frame.version == 1 else { return nil }
      return .transfer(frame.message)
    default:
      return nil
    }
  }

  static func encode(_ message: ScreenSharingClipboardMessage) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? encoder.encode(Frame(message: message))).map { String(decoding: $0, as: UTF8.self) }
  }

  static func viewer(sharing: Bool) -> String { #"{"type":"clipboard-viewer","sharing":\#(sharing)}"# }

  private struct Header: Decodable { let type: String }
  private struct Host: Decodable { let richContent: Bool }
  private struct Frame: Codable {
    var type = "clipboard"
    var version = 1
    let message: ScreenSharingClipboardMessage
  }
}
