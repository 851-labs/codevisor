#if os(macOS)
  import AppKit

  /// Sends the host's pointer on the cursor channel (851-2377): its position at 120 Hz
  /// while it moves, and its image whenever it changes. Polling, drawing and encoding run
  /// on the poller's own serial queue; the main actor only starts and stops it and sends a
  /// message that changed. The system, the display, the clock and the channel are behind
  /// closures, so a test drives `tick()` with scripted pointers.
  @MainActor
  public final class ScreenSharingCursorPublisher {
    /// What the system says about the pointer right now.
    public struct Pointer {
      /// Global position, in points, origin at the top left of the main display (CGEvent's space).
      public var location: CGPoint
      public var image: NSImage
      /// In the image's points, origin top left.
      public var hotSpot: CGPoint
      public init(location: CGPoint, image: NSImage, hotSpot: CGPoint) {
        self.location = location; self.image = image; self.hotSpot = hotSpot
      }
    }

    public nonisolated static let positionInterval: Duration = .microseconds(8_333)
    /// Shapes are looked at every this many position ticks (40 Hz): looking costs more than a position.
    nonisolated static let shapeEvery = 3
    /// The display's backing scale is read again after this many ticks (a second), or sooner when its
    /// area changes: asking for the display mode is too slow for every shape tick.
    nonisolated static let scaleEvery = 120

    private let makePoller: () -> Poller
    private let send: (ScreenSharingCursorMessage) -> Bool
    private let clock: any Clock<Duration>
    private var poller: Poller
    /// Bumped by `stop()`, so a tick still in flight when it stopped sends nothing.
    private var generation = 0
    private var timer: Task<Void, Never>?

    /// `bounds`, `scale` and `pointer` are called on the poller's queue; `send` on the main actor,
    /// only for a message that changed. `metrics` counts the shapes drawn.
    public init(
      bounds: @escaping @Sendable () -> CGRect, scale: @escaping @Sendable () -> CGFloat,
      pointer: @escaping @Sendable () -> Pointer? = { ScreenSharingCursorPublisher.systemPointer() },
      metrics: ScreenSharingMetrics? = nil, clock: any Clock<Duration> = ContinuousClock(),
      send: @escaping (ScreenSharingCursorMessage) -> Bool
    ) {
      let makePoller = { Poller(bounds: bounds, scale: scale, pointer: pointer, metrics: metrics) }
      self.makePoller = makePoller; poller = makePoller(); self.send = send; self.clock = clock
    }

    deinit { timer?.cancel() }

    /// Starts sending from scratch: the current shape and position go out on the first tick.
    public func start() {
      stop()
      poller = makePoller()
      let poller = poller, clock = clock, deliver = deliverer()
      timer = Task.detached(priority: .userInitiated) {
        await poller.run(every: Self.positionInterval, clock: clock, deliver: deliver)
      }
    }

    /// Nothing is sent after this returns, even by a tick that was already running.
    public func stop() {
      generation += 1
      timer?.cancel()
      timer = nil
    }

    /// One poll, as the timer runs it.
    func tick() async { await poller.tick(deliver: deliverer()) }

    /// Sends on the main actor for the current generation; a later `stop()` turns it into a refusal.
    private func deliverer() -> @MainActor @Sendable (ScreenSharingCursorMessage) -> Bool {
      let generation = generation
      return { [weak self] message in
        guard let self, self.generation == generation else { return false }
        return self.send(message)
      }
    }

    /// The polling half: what went out last, isolated to its own serial queue so that reading the
    /// pointer, drawing and encoding it never run on the main thread.
    actor Poller {
      private let queue = DispatchSerialQueue(label: "codevisor.screen-sharing.cursor", qos: .userInteractive)
      nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
      /// The captured area in the same global point space as `Pointer.location`.
      private let bounds: @Sendable () -> CGRect
      /// Pixels per point for the images: the captured display's backing scale.
      private let scale: @Sendable () -> CGFloat
      private let pointer: @Sendable () -> Pointer?
      private let metrics: ScreenSharingMetrics?
      private var lastPosition: ScreenSharingPointer??
      private var lastShape: ScreenSharingCursorImage?
      /// What the pointer looked like when `lastShape` went out: while it still does, nothing is drawn.
      private var lastLook: Look?
      /// The latest drawing, so a shape the channel refused goes again without being drawn again.
      private var drawn: (look: Look, image: ScreenSharingCursorImage?)?
      private var cachedScale: (value: CGFloat, area: CGRect, tick: Int)?
      private var ticks = 0

      init(
        bounds: @escaping @Sendable () -> CGRect, scale: @escaping @Sendable () -> CGFloat,
        pointer: @escaping @Sendable () -> Pointer?, metrics: ScreenSharingMetrics?
      ) {
        self.bounds = bounds; self.scale = scale; self.pointer = pointer; self.metrics = metrics
      }

      func run(
        every interval: Duration, clock: any Clock<Duration>,
        deliver: @escaping @MainActor @Sendable (ScreenSharingCursorMessage) -> Bool
      ) async {
        while !Task.isCancelled {
          await tick(deliver: deliver)
          do { try await clock.sleep(for: interval) } catch { return }
        }
      }

      /// One poll: the position if it moved, and every `shapeEvery` ticks the image if it changed.
      /// A message the channel refused is sent again on a later tick.
      func tick(deliver: @MainActor @Sendable (ScreenSharingCursorMessage) -> Bool) async {
        let tick = ticks
        ticks += 1
        guard let pointer = pointer() else { return }
        let area = bounds()
        if tick % ScreenSharingCursorPublisher.shapeEvery == 0,
          let change = changedShape(pointer, area: area, tick: tick), await deliver(.shape(change.shape))
        {
          lastShape = change.shape
          lastLook = change.look
        }
        let position = ScreenSharingCursorPublisher.position(pointer.location, in: area)
        if lastPosition != .some(position), await deliver(.position(position)) { lastPosition = position }
      }

      /// The shape to send when the pointer no longer looks like the last one sent. It is drawn and
      /// encoded only for a new look (or every time for an image without a bitmap to compare).
      private func changedShape(
        _ pointer: Pointer, area: CGRect, tick: Int
      ) -> (look: Look?, shape: ScreenSharingCursorImage)? {
        let scale = displayScale(area: area, tick: tick)
        let look = Look(pointer, area: area.size, scale: scale)
        if let look, look == lastLook { return nil }
        let shape: ScreenSharingCursorImage?
        if let look, let drawn, drawn.look == look {
          shape = drawn.image
        } else {
          shape = ScreenSharingCursorPublisher.image(pointer, area: area, scale: scale)
          metrics?.increment("cursorShapesDrawn")
          drawn = look.map { ($0, shape) }
        }
        guard let shape else { return nil }
        guard shape != lastShape else {
          lastLook = look
          return nil
        }
        return (look, shape)
      }

      private func displayScale(area: CGRect, tick: Int) -> CGFloat {
        if let cachedScale, cachedScale.area == area, tick - cachedScale.tick < ScreenSharingCursorPublisher.scaleEvery
        {
          return cachedScale.value
        }
        let value = scale()
        cachedScale = (value, area, tick)
        return value
      }
    }

    /// What a pointer looks like, cheaply: its pixels and hot spot, and what it is drawn for. Two
    /// pointers that look alike draw the same shape; the system hands out a new image every poll.
    struct Look: Equatable {
      var hotSpot: CGPoint
      var size: CGSize
      var area: CGSize
      var scale: CGFloat
      var pixelWidth: Int
      var pixelHeight: Int
      var bytesPerRow: Int
      var bitsPerPixel: Int
      var pixels: Data

      /// Nil when the image has no bitmap to compare.
      init?(_ pointer: Pointer, area: CGSize, scale: CGFloat) {
        guard let image = pointer.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let pixels = image.dataProvider?.data
        else { return nil }
        hotSpot = pointer.hotSpot; size = pointer.image.size; self.area = area; self.scale = scale
        pixelWidth = image.width; pixelHeight = image.height
        bytesPerRow = image.bytesPerRow; bitsPerPixel = image.bitsPerPixel
        self.pixels = pixels as Data
      }
    }

    /// Normalized in `area`, origin top left; nil outside it.
    nonisolated static func position(_ location: CGPoint, in area: CGRect) -> ScreenSharingPointer? {
      guard area.width > 0, area.height > 0, (area.minX...area.maxX).contains(location.x),
        (area.minY...area.maxY).contains(location.y)
      else { return nil }
      return ScreenSharingPointer(x: (location.x - area.minX) / area.width, y: (location.y - area.minY) / area.height)
    }

    /// The pointer image at `scale` pixels per point (1× if 2× doesn't fit a message), sized
    /// as a share of `area`.
    nonisolated static func image(_ pointer: Pointer, area: CGRect, scale: CGFloat) -> ScreenSharingCursorImage? {
      let size = pointer.image.size
      guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return nil }
      for pixelsPerPoint in Set([max(1, min(2, scale)), 1]).sorted(by: >) {
        let width = Int((size.width * pixelsPerPoint).rounded()), height = Int((size.height * pixelsPerPoint).rounded())
        guard width <= RFBCursorShape.maximumDimension, height <= RFBCursorShape.maximumDimension,
          let png = ScreenSharingCursorImage.png(
            pixelWidth: width, pixelHeight: height,
            draw: { context in
              NSGraphicsContext.saveGraphicsState()
              NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
              pointer.image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
              NSGraphicsContext.restoreGraphicsState()
            })
        else { continue }
        let image = ScreenSharingCursorImage(
          png: png,
          hotspotX: min(width - 1, max(0, Int(pointer.hotSpot.x * pixelsPerPoint))),
          hotspotY: min(height - 1, max(0, Int(pointer.hotSpot.y * pixelsPerPoint))),
          width: size.width / area.width, height: size.height / area.height)
        if (try? ScreenSharingCursorMessage.shape(image).encoded()) != nil { return image }
      }
      return nil
    }

    /// The system's pointer: any app's shape (not just this one's), and its location.
    public nonisolated static func systemPointer() -> Pointer? {
      guard let location = CGEvent(source: nil)?.location, let cursor = NSCursor.currentSystem else { return nil }
      return Pointer(location: location, image: cursor.image, hotSpot: cursor.hotSpot)
    }

    /// A display's area in the pointer's space, and its backing scale.
    public nonisolated static func displayArea(_ displayID: CGDirectDisplayID) -> CGRect {
      CGDisplayBounds(displayID)
    }
    public nonisolated static func displayScale(_ displayID: CGDirectDisplayID) -> CGFloat {
      guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
      return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
  }
#endif
