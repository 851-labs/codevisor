import ScreenSharingBench

struct SceneWords {
  private static let vocabulary = [
    "frame", "pixel", "encoder", "latency", "buffer", "display", "capture", "stream", "packet", "decode",
    "render", "surface", "texture", "version", "barcode", "glass", "network", "jitter", "viewer", "host",
    "session", "window", "scroll", "cursor", "glyph", "kernel", "queue", "socket", "signal", "timer",
    "metal", "layer", "commit", "present", "vsync", "refresh", "motion", "bitrate", "keyframe", "slice",
    "let", "var", "func", "return", "guard", "struct", "enum", "case", "switch", "await",
  ]

  private var random: SplitMix64

  init(seed: UInt64, stream: UInt64) {
    random = SplitMix64(seed: seed ^ stream &* 0x9E37_79B9_7F4A_7C15)
  }

  mutating func word() -> String {
    Self.vocabulary[Int(random.next() % UInt64(Self.vocabulary.count))]
  }

  mutating func line(columns: Int) -> String {
    let target = columns / 2 + Int(random.next() % UInt64(max(1, columns / 2)))
    var line = word()
    while true {
      let next = word()
      guard line.count + 1 + next.count <= target else { return line }

      line += " " + next
    }
  }
}
