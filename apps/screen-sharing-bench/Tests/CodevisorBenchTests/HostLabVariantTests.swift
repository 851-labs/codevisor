import Testing

@testable import CodevisorBench

struct HostLabVariantTests {
  @Test func parsesSettingsAndPassesThemToTheRun() throws {
    let variant = try HostLabVariant(parsing: "queue=6,cursor=0,refine=1,converge=900,tiles=1,ltr=0,fps=30")

    #expect(
      variant.arguments == [
        "--variant", "queue=6,cursor=0,refine=1,converge=900,tiles=1,ltr=0,fps=30", "--queue", "6", "--cursor", "0",
        "--fps", "30", "--refine", "1", "--converge", "900", "--ltr", "0", "--tiles", "1",
      ])
  }

  @Test(arguments: ["queue=9", "tiles=2", "speed=1", "cursor"])
  func rejectsUnknownOrOutOfRangeSettings(text: String) {
    #expect(throws: BenchUsageError.self) { try HostLabVariant(parsing: text) }
  }
}
