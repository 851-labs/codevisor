import ScreenSharing

/// A deterministic desktop workload for the reference server: each `next`
/// changes the framebuffer the way a real desktop would for that activity and
/// returns the rectangles that describe the change on the wire. A scene is a
/// function of its kind, seed and frame count, never of wall time, so tests,
/// `vnc-bench` and the rig replay exactly the same content.
public struct RFBLoopbackScene: Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    /// Nothing changes.
    case idle
    /// Glyph-sized rectangles appear along lines, like typing in an editor.
    case typing
    /// Content moves up (CopyRect) and a new strip appears at the bottom.
    case scroll
    /// A window moves across a static background.
    case windowDrag
    /// High-entropy full-frame content, like a photo or video.
    case photo
    /// The desktop alternates between two sizes and is repainted.
    case resize
  }

  public let kind: Kind
  public let seed: UInt64
  public private(set) var frame = 0
  private var random: SplitMix64
  private var caret = (x: 0, y: 0)
  private var window: RFBRectangle?
  private var baseSize: (width: Int, height: Int)?

  public init(kind: Kind, seed: UInt64) {
    self.kind = kind
    self.seed = seed
    random = SplitMix64(seed: seed ^ kind.rawValue.stableHash)
  }

  /// Applies the next frame to `framebuffer` and returns its rectangles, in
  /// the order the client must apply them. Empty when nothing changed.
  public mutating func next(on framebuffer: RFBFramebuffer) throws -> [RFBLoopbackServer.Rectangle] {
    defer { frame += 1 }
    switch kind {
    case .idle: return []
    case .typing: return try typing(framebuffer)
    case .scroll: return try scroll(framebuffer)
    case .windowDrag: return try windowDrag(framebuffer)
    case .photo: return try photo(framebuffer)
    case .resize: return try resize(framebuffer)
    }
  }

  // MARK: Scenes

  private static let glyph = (width: 8, height: 12)

  private mutating func typing(_ framebuffer: RFBFramebuffer) throws -> [RFBLoopbackServer.Rectangle] {
    let (width, height) = Self.glyph
    if caret.x + width > framebuffer.width {
      caret = (0, caret.y + height)
    }
    if caret.y + height > framebuffer.height {
      caret = (0, 0)
    }
    let rect = RFBRectangle(x: caret.x, y: caret.y, width: width, height: height)
    // Ink on paper: a random glyph-like bit pattern in one colour.
    let ink = (UInt8(random.next() & 0x7F), UInt8(random.next() & 0x7F), UInt8(random.next() & 0x7F))
    var pixels = [UInt8]()
    pixels.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) {
      let on = random.next() & 3 == 0
      pixels += on ? [ink.0, ink.1, ink.2, 255] : [250, 250, 250, 255]
    }
    try framebuffer.fillRaw(rect, from: pixels)
    caret.x += width
    return [.encoded(rect)]
  }

  private static let scrollStep = 12

  private mutating func scroll(_ framebuffer: RFBFramebuffer) throws -> [RFBLoopbackServer.Rectangle] {
    let step = min(Self.scrollStep, framebuffer.height)
    let width = framebuffer.width
    var rectangles: [RFBLoopbackServer.Rectangle] = []
    if framebuffer.height > step {
      let moved = RFBRectangle(x: 0, y: 0, width: width, height: framebuffer.height - step)
      try framebuffer.copy(moved, fromX: 0, fromY: step)
      rectangles.append(.moved(moved, fromX: 0, fromY: step))
    }
    let strip = RFBRectangle(x: 0, y: framebuffer.height - step, width: width, height: step)
    try framebuffer.fillRaw(strip, from: noise(count: width * step, spread: 64))
    rectangles.append(.encoded(strip))
    return rectangles
  }

  private mutating func windowDrag(_ framebuffer: RFBFramebuffer) throws -> [RFBLoopbackServer.Rectangle] {
    let size = (width: max(1, framebuffer.width / 3), height: max(1, framebuffer.height / 3))
    let old = window ?? RFBRectangle(x: 0, y: 0, width: size.width, height: size.height)
    let dx = Int(random.next() % 9) - 4, dy = Int(random.next() % 9) - 4
    let new = RFBRectangle(
      x: min(max(0, old.x + dx), framebuffer.width - size.width),
      y: min(max(0, old.y + dy), framebuffer.height - size.height),
      width: size.width, height: size.height)
    // A frame gets the whole desktop painted once, then only the window's travel.
    let dirty: RFBRectangle
    if window == nil {
      try framebuffer.fill(
        RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height), blue: 90, green: 60, red: 40)
      dirty = RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
    } else {
      try framebuffer.fill(old, blue: 90, green: 60, red: 40)
      dirty = old.union(new)
    }
    try framebuffer.fill(new, blue: 230, green: 230, red: 230)
    try framebuffer.fill(
      RFBRectangle(x: new.x, y: new.y, width: new.width, height: min(new.height, 6)), blue: 200, green: 120,
      red: 60)
    window = new
    return [.encoded(dirty)]
  }

  private mutating func photo(_ framebuffer: RFBFramebuffer) throws -> [RFBLoopbackServer.Rectangle] {
    let full = RFBRectangle(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
    var pixels = [UInt8]()
    pixels.reserveCapacity(full.width * full.height * 4)
    let phase = frame * 3
    for y in 0..<full.height {
      for x in 0..<full.width {
        let jitter = UInt8(random.next() & 0x1F)
        pixels += [
          UInt8(truncatingIfNeeded: x * 2 + phase) &+ jitter, UInt8(truncatingIfNeeded: y * 3 + phase) &+ jitter,
          UInt8(truncatingIfNeeded: (x + y) + phase) &+ jitter, 255,
        ]
      }
    }
    try framebuffer.fillRaw(full, from: pixels)
    return [.encoded(full)]
  }

  private mutating func resize(_ framebuffer: RFBFramebuffer) throws -> [RFBLoopbackServer.Rectangle] {
    let base = baseSize ?? (framebuffer.width, framebuffer.height)
    baseSize = base
    let small = frame % 2 == 0
    let width = small ? max(1, base.width * 3 / 4) : base.width
    let height = small ? max(1, base.height * 3 / 4) : base.height
    try framebuffer.resize(width: width, height: height)
    let full = RFBRectangle(x: 0, y: 0, width: width, height: height)
    try framebuffer.fillRaw(full, from: noise(count: width * height, spread: 32))
    return [.desktopSize(width: width, height: height), .encoded(full)]
  }

  /// `count` BGRA pixels around a random base colour.
  private mutating func noise(count: Int, spread: UInt64) -> [UInt8] {
    let base = (UInt8(random.next() & 0xBF), UInt8(random.next() & 0xBF), UInt8(random.next() & 0xBF))
    var pixels = [UInt8]()
    pixels.reserveCapacity(count * 4)
    for _ in 0..<count {
      pixels += [
        base.0 &+ UInt8(random.next() % spread), base.1 &+ UInt8(random.next() % spread),
        base.2 &+ UInt8(random.next() % spread), 255,
      ]
    }
    return pixels
  }
}

/// A small, fast, seedable generator (Vigna's SplitMix64): the same seed gives
/// the same sequence on every machine and Swift version.
public struct SplitMix64: RandomNumberGenerator, Sendable {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

extension String {
  /// FNV-1a: `hashValue` is randomised per process, this is not.
  fileprivate var stableHash: UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    return hash
  }
}

extension RFBRectangle {
  fileprivate func union(_ other: RFBRectangle) -> RFBRectangle {
    let minX = min(x, other.x), minY = min(y, other.y)
    return RFBRectangle(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
  }
}
