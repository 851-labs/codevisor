import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@Suite("Composer skill palette")
struct ComposerSkillPaletteTests {
  /// `|` marks the caret; `expected` is the trigger and query, or nil when
  /// the palette must stay closed.
  @Test(
    "Opens on a / or $ token at the caret, never inside words or paths",
    arguments: [
      ("/|", "/:"),
      ("$|", "$:"),
      ("/Rev|", "/:rev"),
      ("$rev|", "$:rev"),
      ("fix this /rev|", "/:rev"),
      ("fix this\n$rev|", "$:rev"),
      ("/rev| and more", "/:rev"),
      ("src/foo|", nil),
      ("/usr/bin|", nil),
      ("US$5|", nil),
      ("$HOME/x|", nil),
      ("costs $5 |", nil),
      ("/rev now|", nil),
    ] as [(String, String?)]
  )
  func tokenDetection(marked: String, expected: String?) throws {
    let caret = try #require(marked.firstIndex(of: "|"))
    let text = marked.replacingOccurrences(of: "|", with: "")
    let location = NSRange(caret..<caret, in: marked).location

    let token = ComposerSlashToken(in: text, selection: NSRange(location: location, length: 0))

    #expect(token.map { "\($0.trigger.rawValue):\($0.query)" } == expected)
    if let token {
      // The range spans trigger through caret, the span acceptance replaces.
      #expect(NSMaxRange(token.range) == location)
      #expect((text as NSString).substring(with: token.range).lowercased() == "\(token.trigger.rawValue)\(token.query)")
    }
  }

  @Test("A non-empty selection never opens the palette")
  func selectionRange() {
    #expect(ComposerSlashToken(in: "/rev", selection: NSRange(location: 1, length: 3)) == nil)
  }

  @Test("Codevisor skills use the harness prefix and yield to native names")
  func mergesCodevisorSkills() {
    let native = SessionSkills(
      skills: [
        SessionSkill(name: "review", description: "Native review", invocation: "$review", source: .project),
        SessionSkill(name: "Lint", invocation: "$Lint", source: .builtin),
      ],
      invocationPrefix: "$"
    )
    let codevisor = [
      ServerComposerSkill(name: "review"),
      ServerComposerSkill(name: "deploy", description: "Ship"),
      ServerComposerSkill(name: "browser-use", description: "Browse the web", builtin: true),
      ServerComposerSkill(name: "lint"),
    ]

    let merged = ComposerSkillCatalog.merge(native: native, codevisor: codevisor)

    #expect(
      merged == [
        SessionSkill(
          name: "browser-use", description: "Browse the web", invocation: "$browser-use", source: .codevisor),
        SessionSkill(name: "deploy", description: "Ship", invocation: "$deploy", source: .codevisor),
        SessionSkill(name: "Lint", invocation: "$Lint", source: .builtin),
        SessionSkill(name: "review", description: "Native review", invocation: "$review", source: .project),
      ])
  }

  @Test("Codevisor skills default to the slash prefix before the harness reports skills")
  func codevisorSkillsWithoutNativeList() {
    let merged = ComposerSkillCatalog.merge(native: nil, codevisor: [ServerComposerSkill(name: "deploy")])

    #expect(merged.map(\.invocation) == ["/deploy"])
  }

  @Test("Matches rank exact, then prefix, then substring names, case-insensitively")
  func matchRanking() {
    let skills = ["code-review", "Review", "review-pr", "deploy", "preview"].map {
      SessionSkill(name: $0, invocation: "/\($0)")
    }

    #expect(
      ComposerSkillCatalog.matches(skills, query: "review").map(\.name)
        == ["Review", "review-pr", "code-review", "preview"])
    #expect(ComposerSkillCatalog.matches(skills, query: "").map(\.name) == skills.map(\.name))
    #expect(ComposerSkillCatalog.matches(skills, query: "xyz").isEmpty)
  }
}
