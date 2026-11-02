import Foundation
import Testing

@testable import CodevisorUI

@Suite("CSV and TSV table previews")
struct DelimitedTablePreviewTests {
  @Test("Quoted fields keep delimiters, doubled quotes and line breaks")
  func quotedFields() {
    let csv = "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\nthen left\"\r\nplain,\n"
    #expect(
      DelimitedTextTable.rows(in: csv, delimiter: ",") == [
        ["name", "note"], ["Smith, J", "said \"hi\"\nthen left"], ["plain", ""],
      ])
  }

  @Test("Tabs split TSV columns and an unterminated quote fails")
  func tabsAndBrokenQuotes() {
    #expect(DelimitedTextTable.rows(in: "a\tb\n1\t2", delimiter: "\t") == [["a", "b"], ["1", "2"]])
    #expect(DelimitedTextTable.rows(in: "a,b\n\"open,2", delimiter: ",") == nil)
  }

  @Test("Shows the header and first ten rows and counts the rest")
  func truncation() throws {
    let lines = ["region,p95"] + (1...13).map { "r\($0),\($0)" }
    let table = try #require(DelimitedTablePreview(data: Data(lines.joined(separator: "\n").utf8), delimiter: ","))

    #expect(table.headers == ["region", "p95"])
    #expect(table.rows.count == 10)
    #expect(table.hiddenRowsNote == "3 more rows")
  }

  @Test("Rows wider than the header aren't a table; shorter rows are padded")
  func rowWidths() throws {
    #expect(DelimitedTablePreview(data: Data("a,b\n1,2,3".utf8), delimiter: ",") == nil)
    let padded = try #require(DelimitedTablePreview(data: Data("a,b,c\n1".utf8), delimiter: ","))
    #expect(padded.rows == [["1", "", ""]])
    #expect(padded.hiddenRowsNote == nil)
  }
}
