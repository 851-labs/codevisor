#if os(macOS)
  import AppKit

  @MainActor
  public final class ScreenSharingCursorPublisher {
    public struct Pointer {
      public var location: CGPoint
      public var image: NSImage
      public var hotSpot: CGPoint
      public init(location: CGPoint, image: NSImage, hotSpot: CGPoint) {
        self.location = location; self.image = image; self.hotSpot = hotSpot
      }
    }

    public nonisolated static let positionInterval: Duration = .microseconds(8_333)
    nonisolated static let shapeEvery = 3
    nonisolated static let scaleEvery = 120

    private let makePoller: () -> Poller
    private let send: (ScreenSharingCursorMessage) -> Bool
    private let clock: any Clock<Duration>
    private var poller: Poller
    private var generation = 0
    private var timer: Task<Void, Never>?

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

    public func start() {
      stop()
      poller = makePoller()
      let poller = poller, clock = clock, deliver = deliverer()
      timer = Task.detached(priority: .userInitiated) {
        await poller.run(every: Self.positionInterval, clock: clock, deliver: deliver)
      }
    }

    public func stop() {
      generation += 1
      timer?.cancel()
      timer = nil
    }

    func tick() async { await poller.tick(deliver: deliverer()) }

    private func deliverer() -> @MainActor @Sendable (ScreenSharingCursorMessage) -> Bool {
      let generation = generation
      return { [weak self] message in
        guard let self, self.generation == generation else { return false }
        return self.send(message)
      }
    }

    actor Poller {
      private let queue = DispatchSerialQueue(label: "codevisor.screen-sharing.cursor", qos: .userInteractive)
      nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
      private let bounds: @Sendable () -> CGRect
      private let scale: @Sendable () -> CGFloat
      private let pointer: @Sendable () -> Pointer?
      private let metrics: ScreenSharingMetrics?
      private var lastPosition: ScreenSharingPointer??
      private var lastShape: ScreenSharingCursorImage?
      private var lastLook: Look?
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

    nonisolated static func position(_ location: CGPoint, in area: CGRect) -> ScreenSharingPointer? {
      guard area.width > 0, area.height > 0, (area.minX...area.maxX).contains(location.x),
        (area.minY...area.maxY).contains(location.y)
      else { return nil }
      return ScreenSharingPointer(x: (location.x - area.minX) / area.width, y: (location.y - area.minY) / area.height)
    }

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

    public nonisolated static func systemPointer() -> Pointer? {
      guard let location = CGEvent(source: nil)?.location, let cursor = NSCursor.currentSystem else { return nil }
      return Pointer(location: location, image: cursor.image, hotSpot: cursor.hotSpot)
    }

    public nonisolated static func displayArea(_ displayID: CGDirectDisplayID) -> CGRect {
      CGDisplayBounds(displayID)
    }
    public nonisolated static func displayScale(_ displayID: CGDirectDisplayID) -> CGFloat {
      guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
      return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
  }
#endif
