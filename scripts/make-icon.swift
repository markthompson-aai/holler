#!/usr/bin/env swift
// Draws Holler's app icon into Resources/AppIcon.icns, in the style of
// Blurt's: a grainy gradient filling the rounded square, with the name in
// lowercase across the middle. Blurt runs indigo through black to green;
// Holler runs indigo through its warm off-black to the lavender of the dark
// note's accent, with the name in the light note's cream (NoteTheme.swift).
// No dependencies beyond AppKit and iconutil, so it runs with the Command
// Line Tools alone.
//
//   swift scripts/make-icon.swift
//
// The icon is committed, so this only needs running when the palette
// changes. scripts/build-app.sh copies it into the app.
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = repo.appendingPathComponent("Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")

func color(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
    alpha: 1)
}

let indigo = color(0x3F2B_C1)  // Palette.light.accent
let ink = color(0x1B1A_18)  // Palette.light.ink, the warm off-black
let lavender = color(0x8B7C_EE)  // Palette.dark.accent, a shade deeper
let cream = color(0xFBF8_F2)  // Palette.light.surface

// Apple's icon grid: a 1024 canvas with the rounded square on 824, and a
// corner radius just under a quarter of its side.
let canvas: CGFloat = 1024
let inset: CGFloat = 100
let square = NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let cornerRadius = square.width * 0.2237

/// The background at full size: the gradient, with film grain so flat areas
/// don't band and the icon has Blurt's texture. Drawn once and scaled down
/// for each size, so the grain softens as the icon shrinks.
func background() -> NSImage {
  let pixels = Int(canvas)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  // Indigo at the top, the off-black behind the word, lavender at the foot.
  NSGradient(colorsAndLocations: (lavender, 0), (ink, 0.5), (indigo, 1))!
    .draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: 80)
  NSGraphicsContext.restoreGraphicsState()

  // Grain: the same small random offset on every channel of a pixel.
  var generator = SystemRandomNumberGenerator()
  let data = rep.bitmapData!
  let bytesPerRow = rep.bytesPerRow
  for y in 0..<pixels {
    let row = data + y * bytesPerRow
    for x in 0..<pixels {
      let pixel = row + x * 4
      let grain = Int.random(in: -18...18, using: &generator)
      for channel in 0..<3 {
        pixel[channel] = UInt8(clamping: Int(pixel[channel]) + grain)
      }
    }
  }
  let image = NSImage(size: NSSize(width: canvas, height: canvas))
  image.addRepresentation(rep)
  return image
}

let backgroundImage = background()

/// The wordmark: lowercase, heavy and a little tight, about seven tenths of
/// the square wide. Avenir Next ships with macOS; the system face is the fallback.
func wordmark(scale: CGFloat) -> NSAttributedString {
  let size = 236 * scale
  let font = NSFont(name: "AvenirNext-Heavy", size: size) ?? .systemFont(ofSize: size, weight: .heavy)
  return NSAttributedString(
    string: "holler", attributes: [.font: font, .foregroundColor: cream, .kern: -0.035 * size])
}

func draw(side: CGFloat) {
  let scale = side / canvas
  let shape = NSBezierPath(
    roundedRect: NSRect(
      x: square.minX * scale, y: square.minY * scale, width: square.width * scale, height: square.height * scale),
    xRadius: cornerRadius * scale, yRadius: cornerRadius * scale)
  NSGraphicsContext.saveGraphicsState()
  shape.addClip()
  backgroundImage.draw(
    in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
  let text = wordmark(scale: scale)
  let bounds = text.boundingRect(with: NSSize(width: side, height: side), options: [.usesLineFragmentOrigin])
  // Centre on the x-height, not the line box, so the word sits in the middle optically.
  let font = text.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
  let xHeight = font.xHeight
  let baseline = side / 2 - xHeight / 2
  text.draw(at: NSPoint(x: side / 2 - bounds.width / 2, y: baseline + font.descender))
  NSGraphicsContext.restoreGraphicsState()
}

func render(pixels: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  draw(side: CGFloat(pixels))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try render(pixels: size * scale).write(to: iconset.appendingPathComponent(name))
  }
}
// A full-size preview beside the icns, for a look without opening the app.
let preview = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
if let preview { try render(pixels: 1024).write(to: preview) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
  FileHandle.standardError.write(Data("iconutil failed (\(iconutil.terminationStatus))\n".utf8))
  exit(1)
}
print("wrote \(output.path)")
