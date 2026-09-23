import Foundation
import ScreenSharing

/// The reference server's wire encoding of queued rectangles: Raw, CopyRect,
/// ZRLE and the pseudo-encodings (cursor, pointer, sizes).
extension RFBLoopbackServer {
  func encode(_ rectangles: [Rectangle]) throws -> [UInt8] {
    var writer = RFBByteWriter()
    writer.u8(0); writer.pad(1); writer.u16(UInt16(rectangles.count))
    for rectangle in rectangles {
      switch rectangle {
      case .raw(let rect):
        header(&writer, rect, .raw)
        writer.append(rows(rect))
      case .copy(let rect, let fromX, let fromY):
        header(&writer, rect, .copyRect)
        writer.u16(UInt16(fromX)); writer.u16(UInt16(fromY))
        try framebuffer.copy(rect, fromX: fromX, fromY: fromY)
      case .moved(let rect, let fromX, let fromY):
        header(&writer, rect, .copyRect)
        writer.u16(UInt16(fromX)); writer.u16(UInt16(fromY))
      case .encoded(let rect):
        switch pixelEncoding {
        case .tight:
          header(&writer, rect, .tight)
          writer.append(try tightEncoder.encode(rect, from: framebuffer, qualityLevel: clientQualityLevel))
        case .zrle:
          header(&writer, rect, .zrle)
          if deflater == nil { deflater = try RFBZlibDeflater() }
          let compressed = try deflater!.deflate(zrleTiles(rect))
          writer.u32(UInt32(compressed.count)); writer.append(compressed)
        default:
          header(&writer, rect, .raw)
          writer.append(rows(rect))
        }
      case .zrle(let rect):
        header(&writer, rect, .zrle)
        if deflater == nil { deflater = try RFBZlibDeflater() }
        let compressed = try deflater!.deflate(zrleTiles(rect))
        writer.u32(UInt32(compressed.count)); writer.append(compressed)
      case .cursor(let shape):
        header(
          &writer, RFBRectangle(x: shape.hotspotX, y: shape.hotspotY, width: shape.width, height: shape.height), .cursor
        )
        writer.append(shape.encodedPayload())
      case .pointer(let point):
        header(&writer, RFBRectangle(x: point.x, y: point.y, width: 0, height: 0), .pointerPosition)
      case .extendedDesktopSize(let result):
        header(
          &writer,
          RFBRectangle(
            x: result.reason.rawValue, y: result.status.rawValue, width: result.width, height: result.height),
          .extendedDesktopSize)
        writer.u8(UInt8(result.screens.count)); writer.pad(3)
        for screen in result.screens { RFBScreenLayout.write(screen, into: &writer) }
      case .desktopSize(let width, let height):
        header(&writer, RFBRectangle(x: 0, y: 0, width: width, height: height), .desktopSize)
        // A scene resizes and repaints before sending; resizing again would clear its content.
        if framebuffer.width != width || framebuffer.height != height {
          try framebuffer.resize(width: width, height: height)
        }
      }
    }
    return writer.bytes
  }

  func header(_ writer: inout RFBByteWriter, _ rect: RFBRectangle, _ encoding: RFBEncoding) {
    writer.u16(UInt16(rect.x)); writer.u16(UInt16(rect.y))
    writer.u16(UInt16(rect.width)); writer.u16(UInt16(rect.height))
    writer.s32(encoding.rawValue)
  }

  func rows(_ rect: RFBRectangle) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(rect.width * rect.height * 4)
    for y in rect.y..<rect.maxY {
      let start = (y * framebuffer.width + rect.x) * 4
      bytes.append(contentsOf: framebuffer.pixels[start..<start + rect.width * 4])
    }
    return bytes
  }

  /// Solid tiles where the tile is one colour, raw tiles otherwise.
  func zrleTiles(_ rect: RFBRectangle) -> [UInt8] {
    var bytes: [UInt8] = []
    var tileY = rect.y
    while tileY < rect.maxY {
      let tileHeight = min(RFBZRLEDecoder.tile, rect.maxY - tileY)
      var tileX = rect.x
      while tileX < rect.maxX {
        let tileWidth = min(RFBZRLEDecoder.tile, rect.maxX - tileX)
        var cpixels: [UInt8] = []
        cpixels.reserveCapacity(tileWidth * tileHeight * 3)
        for y in tileY..<tileY + tileHeight {
          for x in tileX..<tileX + tileWidth {
            let index = (y * framebuffer.width + x) * 4
            cpixels.append(contentsOf: framebuffer.pixels[index..<index + 3])
          }
        }
        let first = Array(cpixels.prefix(3))
        let solid = stride(from: 0, to: cpixels.count, by: 3).allSatisfy { Array(cpixels[$0..<$0 + 3]) == first }
        if solid {
          bytes.append(1); bytes.append(contentsOf: first)
        } else {
          bytes.append(0); bytes.append(contentsOf: cpixels)
        }
        tileX += RFBZRLEDecoder.tile
      }
      tileY += RFBZRLEDecoder.tile
    }
    return bytes
  }
}
