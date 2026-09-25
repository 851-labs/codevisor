#if os(macOS)
  import AppKit

  /// Sends the host's pointer on the cursor channel (851-2377): its position at 120 Hz
  /// while it moves, and its image whenever it changes. The system and the capture
  /// are behind closures, so a test drives `tick()` with scripted pointers.
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

    public static let positionInterval: Duration = .microseconds(8_333)
    /// Shapes are looked at every this many position ticks (40 Hz): rendering one costs more than a position.
    static let shapeEvery = 3

    /// The captured area in the same global point space as `Pointer.location`.
    private let bounds: () -> CGRect
    /// Pixels per point for the images: the captured display's backing scale.
    private let scale: () -> CGFloat
    private let pointer: () -> Pointer?
    private let send: (ScreenSharingCursorMessage) -> Bool
    private var lastPosition: ScreenSharingPointer??
    private var lastShape: ScreenSharingCursorImage?
    private var ticks = 0
    private var timer: Task<Void, Never>?

    public init(
      bounds: @escaping () -> CGRect, scale: @escaping () -> CGFloat,
      pointer: @escaping () -> Pointer? = { ScreenSharingCursorPublisher.systemPointer() },
      send: @escaping (ScreenSharingCursorMessage) -> Bool
    ) {
      self.bounds = bounds; self.scale = scale; self.pointer = pointer; self.send = send
    }

    /// Starts sending from scratch: the current shape and position go out on the first tick.
    public func start() {
      stop()
      lastPosition = nil; lastShape = nil; ticks = 0
      timer = Task { [weak self] in
        while !Task.isCancelled {
          self?.tick()
          do { try await Task.sleep(for: Self.positionInterval) } catch { return }
        }
      }
    }

    public func stop() {
      timer?.cancel()
      timer = nil
    }

    /// One poll: the position if it moved, and every `shapeEvery` ticks the image if it changed.
    /// A message the channel refused is sent again on a later tick.
    public func tick() {
      defer { ticks += 1 }
      guard let pointer = pointer() else { return }
      let area = bounds()
      if ticks % Self.shapeEvery == 0, let shape = Self.image(pointer, area: area, scale: scale()),
        shape != lastShape, send(.shape(shape))
      {
        lastShape = shape
      }
      let position = Self.position(pointer.location, in: area)
      if lastPosition != .some(position), send(.position(position)) { lastPosition = position }
    }

    /// Normalized in `area`, origin top left; nil outside it.
    static func position(_ location: CGPoint, in area: CGRect) -> ScreenSharingPointer? {
      guard area.width > 0, area.height > 0, (area.minX...area.maxX).contains(location.x),
        (area.minY...area.maxY).contains(location.y)
      else { return nil }
      return ScreenSharingPointer(x: (location.x - area.minX) / area.width, y: (location.y - area.minY) / area.height)
    }

    /// The pointer image at `scale` pixels per point (1× if 2× doesn't fit a message), sized
    /// as a share of `area`.
    static func image(_ pointer: Pointer, area: CGRect, scale: CGFloat) -> ScreenSharingCursorImage? {
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
    public static func systemPointer() -> Pointer? {
      guard let location = CGEvent(source: nil)?.location, let cursor = NSCursor.currentSystem else { return nil }
      return Pointer(location: location, image: cursor.image, hotSpot: cursor.hotSpot)
    }

    /// A display's area in the pointer's space, and its backing scale.
    public static func displayArea(_ displayID: CGDirectDisplayID) -> CGRect { CGDisplayBounds(displayID) }
    public static func displayScale(_ displayID: CGDirectDisplayID) -> CGFloat {
      guard let mode = CGDisplayCopyDisplayMode(displayID), mode.width > 0 else { return 2 }
      return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
  }
#endif
