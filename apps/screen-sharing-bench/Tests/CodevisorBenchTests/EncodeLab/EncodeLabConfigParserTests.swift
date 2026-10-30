import Testing

@testable import CodevisorBench

struct EncodeLabConfigParserTests {
  @Test func defaultsToTheProductEncoder() throws {
    let config = try EncodeLabConfigParser.parse(spec: "name=product")

    #expect(config.codec == .hevc444)
    #expect(config.rateControl == .standard)
    #expect(config.prioritizesSpeed)
    #expect(config.tileBitsPerSecond == 45_000_000)
    #expect((config.width, config.height) == (2560, 1440))
    #expect(!config.inputIsYCbCr)
  }

  @Test func splitsTheBitrateAndRateLimitAcrossTiles() throws {
    let config = try EncodeLabConfigParser.parse(
      spec: "name=t,codec=hevc,rc=ll,mbps=8,drl=12@0.5,size=3840x2160,tiles=4,skip=1,ltr=1")

    #expect(config.tileBitsPerSecond == 2_000_000)
    #expect(config.tileRateLimitBytes == 187_500)
    #expect(config.tileHeight == 540)
    #expect(config.skipCleanTiles && config.longTermReferences && config.inputIsYCbCr)
    #expect(!config.prioritizesSpeed)
  }

  @Test(arguments: [
    ("tiles=7", "--configs entry \"tiles=7\": height 1440 doesn't split into 7 even tiles"),
    ("mbps=none", "--configs entry \"mbps=none\": mbps=none needs cq or a preset"),
    ("codec=av1", "--configs entry \"codec=av1\": codec av1"),
    ("fps=30", "--configs entry \"fps=30\": unknown key fps"),
  ])
  func rejectsInvalidConfigs(spec: String, message: String) {
    #expect(throws: BenchUsageError(message: message)) { try EncodeLabConfigParser.parse(spec: spec) }
  }

  @Test func readsSemicolonSeparatedLists() throws {
    let configs = try EncodeLabConfigParser.parse(list: "name=a;name=b,mbps=none,cq=0.6;")

    #expect(configs.map(\.name) == ["a", "b"])
    #expect(configs[1].tileBitsPerSecond == nil)
  }
}
