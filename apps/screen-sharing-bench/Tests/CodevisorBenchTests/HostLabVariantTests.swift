import ScreenSharingV2
import Testing

@testable import CodevisorBench

struct HostLabVariantTests {
  @Test func parsesSettingsAndPassesThemToTheRun() throws {
    let text = "queue=6,cursor=0,refine=1,converge=900,tiles=1,ltr=0,fps=30,vcp=1,bgra=1"
    let variant = try HostLabVariant(parsing: text)

    #expect(
      variant.arguments == [
        "--variant", text, "--queue", "6", "--cursor", "0", "--fps", "30", "--ltr", "0", "--vcp", "1", "--bgra", "1",
        "--refine", "1", "--converge", "900", "--tiles", "1",
      ])
  }

  @Test func leavesTheRefinementPolicyToTheEncoderUnlessAVariantSetsIt() throws {
    #expect(!(try HostLabVariant(parsing: "vcp=1").arguments.contains("--converge")))
    #expect(
      try HostLabVariant(parsing: "converge=200").refinement
        == ScreenSharingV2RefinementPolicy(convergedBelowBytes: 200))
  }

  @Test(arguments: ["queue=9", "tiles=2", "speed=1", "cursor", "vcp=2"])
  func rejectsUnknownOrOutOfRangeSettings(text: String) {
    #expect(throws: BenchUsageError.self) { try HostLabVariant(parsing: text) }
  }
}
