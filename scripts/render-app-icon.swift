#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DockGrid {
  static let canvas = 1024.0
  static let body = 824.0
  static let inset = 100.0
  static let shadowOffsetY = -8.0
  static let shadowBlur = 28.0
  static let shadowOpacity = 0.25
}

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let placeOnDockGrid = arguments.first == "--dock"
if placeOnDockGrid { arguments.removeFirst() }
guard arguments.count == 2 else {
  fail("usage: render-app-icon.swift [--dock] <ictool-export.png> <output.png>", code: 64)
}

let input = URL(fileURLWithPath: arguments[0])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
  let icon = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("error: can't read \(input.path)") }

let canvas =
  placeOnDockGrid ? Int((Double(icon.width) * DockGrid.canvas / DockGrid.body).rounded()) : icon.width
let scale = Double(canvas) / DockGrid.canvas
let inset = placeOnDockGrid ? (DockGrid.inset * scale).rounded() : 0
let context = CGContext(
  data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.interpolationQuality = .high
if placeOnDockGrid {
  context.setShadow(
    offset: CGSize(width: 0, height: DockGrid.shadowOffsetY * scale),
    blur: DockGrid.shadowBlur * scale,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: DockGrid.shadowOpacity)
  )
}
context.draw(icon, in: CGRect(x: inset, y: inset, width: Double(icon.width), height: Double(icon.height)))

let output = URL(fileURLWithPath: arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fail("error: can't write \(output.path)") }
