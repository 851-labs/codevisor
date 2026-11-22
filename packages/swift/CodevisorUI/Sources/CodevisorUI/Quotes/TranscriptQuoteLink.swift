import Foundation

public enum TranscriptQuoteLink {
  public static func url(toQuoteAt index: Int) -> URL {
    URL(string: "\(scheme):\(index)")!
  }

  public static func quoteIndex(of url: URL) -> Int? {
    guard url.scheme == scheme else { return nil }
    return Int(url.absoluteString.dropFirst(scheme.count + 1))
  }

  private static let scheme = "codevisor-quote"
}
