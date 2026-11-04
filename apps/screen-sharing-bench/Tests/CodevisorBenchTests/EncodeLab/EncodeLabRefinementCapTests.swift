import Testing

@testable import CodevisorBench

struct EncodeLabRefinementCapTests {
  @Test func capsRefinementPassesAndRestoresTheChangeCapOnTheNextChange() throws {
    var cap = EncodeLabRefinementCap(config: try EncodeLabConfigParser.parse(spec: "name=c,qpmax=28,refineqp=6"))

    #expect(cap.change(repeats: false) == nil)
    #expect(cap.change(repeats: true) == 6)
    #expect(cap.change(repeats: true) == nil)
    #expect(cap.change(repeats: false) == 28)
  }

  @Test func liftsTheCapEntirelyWhenChangesHaveNone() throws {
    var cap = EncodeLabRefinementCap(config: try EncodeLabConfigParser.parse(spec: "name=c,refineqp=10"))

    #expect(cap.change(repeats: true) == 10)
    #expect(cap.change(repeats: false) == EncodeLabRefinementCap.unrestrictedQP)
  }

  @Test func leavesTheSessionAloneWithoutARefinementCap() throws {
    var cap = EncodeLabRefinementCap(config: try EncodeLabConfigParser.parse(spec: "name=c,qpmax=28"))

    #expect(cap.change(repeats: true) == nil)
    #expect(cap.change(repeats: false) == nil)
  }
}
