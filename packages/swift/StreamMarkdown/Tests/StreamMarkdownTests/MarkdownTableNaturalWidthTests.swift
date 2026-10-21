import Testing

@testable import StreamMarkdown

@Suite("MarkdownTableNaturalWidth")
@MainActor
struct MarkdownTableNaturalWidthTests {
  private let narrow = MarkdownBlock.table(
    headers: ["Month", "Change"], alignments: [.leading, .trailing], rows: [["July", "+4%"]])
  private let wide = MarkdownBlock.table(
    headers: ["Service", "Owner", "Region", "p95 latency", "Status"],
    alignments: [.leading, .leading, .leading, .trailing, .leading],
    rows: [["billing-api", "Payments team", "us-east-1", "180 ms", "Healthy"]])

  @Test("Only tables contribute, and the widest table wins")
  func widestTable() {
    let theme = MarkdownTheme.default
    let narrowWidth = MarkdownTableNaturalWidth.widest(in: [narrow], theme: theme)
    let wideWidth = MarkdownTableNaturalWidth.widest(in: [wide], theme: theme)
    #expect(MarkdownTableNaturalWidth.widest(in: [.paragraph("Totals by month")], theme: theme) == 0)
    #expect(narrowWidth > MarkdownTableMetrics.horizontalPadding * 4)
    #expect(wideWidth > narrowWidth)
    #expect(MarkdownTableNaturalWidth.widest(in: [.paragraph("x"), narrow, wide], theme: theme) == wideWidth)
  }
}
