import CoreGraphics

public enum SidebarDropLine {
  public static func frame(at index: Int, among others: [CGRect]) -> CGRect? {
    guard let last = others.last else { return nil }
    guard others.indices.contains(index) else {
      return CGRect(x: last.minX, y: last.maxY + 1, width: last.width, height: 0)
    }

    let span = others[index]
    let y = index > 0 ? (others[index - 1].maxY + span.minY) / 2 : span.minY - 1
    return CGRect(x: span.minX, y: y, width: span.width, height: 0)
  }

  static func union<RowID: Hashable>(of rows: [RowID], in frames: [RowID: CGRect]) -> CGRect? {
    rows.compactMap { frames[$0] }.reduce(nil) { union, frame in union?.union(frame) ?? frame }
  }
}
