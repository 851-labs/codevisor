import Testing

@testable import TranscriptKit

struct UnifiedDiffTests {
  @Test("A git patch splits into files and hunks with real line numbers")
  func gitPatch() throws {
    let patch = """
      diff --git a/Sources/App.swift b/Sources/App.swift
      index 037fca7..03f11b6 100644
      --- a/Sources/App.swift
      +++ b/Sources/App.swift
      @@ -10,3 +10,4 @@ struct App {
         let name: String
      -  let age: Int
      +  let age: UInt
      +  let city: String
         }
      diff --git a/README.md b/README.md
      new file mode 100644
      --- /dev/null
      +++ b/README.md
      @@ -0,0 +1 @@
      +# Hello
      \\ No newline at end of file
      """
    let diff = try #require(UnifiedDiff(parsing: patch))
    #expect(diff.files.map(\.path) == ["Sources/App.swift", "README.md"])

    let app = diff.files[0]
    #expect(app.hunks.map(\.header) == ["@@ -10,3 +10,4 @@ struct App {"])
    #expect(app.rows.map(\.kind) == [.context, .removed, .added, .added, .context])
    #expect(app.rows.map(\.oldLine) == [10, 11, nil, nil, 12])
    #expect(app.rows.map(\.newLine) == [10, nil, 11, 12, 13])
    #expect(app.totals == LineDiff.Totals(added: 2, removed: 1))

    #expect(diff.files[1].rows.map(\.text) == ["# Hello"])
  }

  @Test("Lines that look like file headers stay rows while their hunk is open")
  func headerLookalikesInsideHunk() throws {
    let patch = """
      --- a/notes.txt
      +++ b/notes.txt
      @@ -1,1 +1,2 @@
      --- old rule
      +++ new rule
      +++ another rule
      """
    let file = try #require(UnifiedDiff(parsing: patch)?.files.first)
    #expect(file.rows.map(\.text) == ["-- old rule", "++ new rule", "++ another rule"])
    #expect(file.rows.map(\.kind) == [.removed, .added, .added])
  }

  @Test("Text without hunks isn't a diff")
  func notADiff() {
    #expect(UnifiedDiff(parsing: "just some notes\n- a list item\n+ another") == nil)
  }
}
