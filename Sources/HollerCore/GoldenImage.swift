import Foundation

/// One pixel's red, green, blue and alpha, out of 255 each.
public struct Pixel: Equatable, Sendable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8
  public var alpha: UInt8

  public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// The largest move of any one channel between the two pixels.
  public func difference(from other: Pixel) -> Int {
    max(
      abs(Int(red) - Int(other.red)), abs(Int(green) - Int(other.green)),
      abs(Int(blue) - Int(other.blue)), abs(Int(alpha) - Int(other.alpha)))
  }
}

/// A bitmap as rows of RGBA bytes, top row first: the form the golden-image
/// check compares, with no image framework behind it.
public struct PixelImage: Equatable, Sendable {
  public let width: Int
  public let height: Int
  /// `width * height * 4` bytes, a pixel's red, green, blue and alpha in turn.
  public var rgba: [UInt8]

  public init(width: Int, height: Int, rgba: [UInt8]) {
    precondition(rgba.count == width * height * 4, "a \(width)×\(height) image needs \(width * height * 4) bytes")
    self.width = width
    self.height = height
    self.rgba = rgba
  }

  public init(width: Int, height: Int, fill: Pixel = Pixel(0, 0, 0, 0)) {
    self.width = width
    self.height = height
    rgba = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: rgba.count, by: 4) {
      (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) = (fill.red, fill.green, fill.blue, fill.alpha)
    }
  }

  public var size: PixelSize { PixelSize(width: width, height: height) }
  public var pixelCount: Int { width * height }

  public subscript(x: Int, y: Int) -> Pixel {
    get {
      precondition(0..<width ~= x && 0..<height ~= y, "(\(x), \(y)) is outside a \(width)×\(height) image")
      return self[y * width + x]
    }
    set {
      precondition(0..<width ~= x && 0..<height ~= y, "(\(x), \(y)) is outside a \(width)×\(height) image")
      self[y * width + x] = newValue
    }
  }

  /// The pixels in row order, for a pass over the whole image.
  public subscript(index: Int) -> Pixel {
    get {
      let i = index * 4
      return Pixel(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }
    set {
      let i = index * 4
      (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]) = (newValue.red, newValue.green, newValue.blue, newValue.alpha)
    }
  }
}

public struct PixelSize: Equatable, Sendable, CustomStringConvertible {
  public let width: Int
  public let height: Int
  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
  public var description: String { "\(width)×\(height)" }
}

/// How far a fresh render may drift from its golden image before it counts
/// as a change. A state renders the same bytes every time on one Mac, so the
/// default lets a channel drift a little, for colour management, and no pixel
/// change outright: the mark changing shape is a couple of hundred pixels,
/// and a digit about as many, so a share of the image would hide them.
public struct GoldenTolerance: Equatable, Sendable {
  /// A pixel has changed when any channel moves by more than this, out of 255.
  public var channel: Int
  /// How many pixels may change before the image fails.
  public var changedPixels: Int

  public init(channel: Int, changedPixels: Int) {
    self.channel = channel
    self.changedPixels = changedPixels
  }

  public static let `default` = GoldenTolerance(channel: 3, changedPixels: 0)
}

public enum GoldenVerdict: Equatable, Sendable {
  case matches(changedPixels: Int, maxChannelDifference: Int)
  case differs(changedPixels: Int, of: Int, maxChannelDifference: Int)
  case sizeDiffers(golden: PixelSize, fresh: PixelSize)

  public var isMatch: Bool {
    if case .matches = self { true } else { false }
  }
}

/// Compares one rendered note state with its committed golden image.
public enum GoldenImage {
  public static func compare(golden: PixelImage, fresh: PixelImage, tolerance: GoldenTolerance = .default)
    -> GoldenVerdict
  {
    guard golden.size == fresh.size else { return .sizeDiffers(golden: golden.size, fresh: fresh.size) }
    var changed = 0
    var maxDifference = 0
    for i in 0..<golden.pixelCount {
      let difference = golden[i].difference(from: fresh[i])
      maxDifference = max(maxDifference, difference)
      if difference > tolerance.channel { changed += 1 }
    }
    if changed > tolerance.changedPixels {
      return .differs(changedPixels: changed, of: golden.pixelCount, maxChannelDifference: maxDifference)
    }
    return .matches(changedPixels: changed, maxChannelDifference: maxDifference)
  }

  /// A picture of the change: red where a pixel moved past the tolerance, or
  /// where only one image has a pixel, and the fresh render faded towards
  /// white everywhere else. As large as the larger of the two.
  public static func difference(golden: PixelImage, fresh: PixelImage, tolerance: GoldenTolerance = .default)
    -> PixelImage
  {
    var diff = PixelImage(
      width: max(golden.width, fresh.width), height: max(golden.height, fresh.height), fill: Pixel(255, 0, 0, 255))
    for y in 0..<min(golden.height, fresh.height) {
      for x in 0..<min(golden.width, fresh.width) {
        let pixel = fresh[x, y]
        guard golden[x, y].difference(from: pixel) <= tolerance.channel else { continue }
        diff[x, y] = Pixel(faded(pixel.red), faded(pixel.green), faded(pixel.blue), 255)
      }
    }
    return diff
  }

  /// Half-way to white.
  private static func faded(_ channel: UInt8) -> UInt8 { UInt8((Int(channel) + 255) / 2) }
}

/// The outcome of checking every rendered state against the golden images.
public struct GoldenReport: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case compared(GoldenVerdict)
    /// A fresh render with no golden image: a new state, yet to be recorded.
    case noGolden
    /// A golden image no state renders any more.
    case noRender
  }

  public struct Entry: Equatable, Sendable {
    public let name: String
    public let outcome: Outcome
  }

  /// One per name in either set, sorted by name.
  public let entries: [Entry]
  public let tolerance: GoldenTolerance

  public static func compare(
    goldens: [String: PixelImage], fresh: [String: PixelImage], tolerance: GoldenTolerance = .default
  ) -> GoldenReport {
    let names = Set(goldens.keys).union(fresh.keys).sorted()
    let entries = names.map { name -> Entry in
      switch (goldens[name], fresh[name]) {
      case (let golden?, let render?):
        Entry(name: name, outcome: .compared(GoldenImage.compare(golden: golden, fresh: render, tolerance: tolerance)))
      case (nil, _): Entry(name: name, outcome: .noGolden)
      case (_, nil): Entry(name: name, outcome: .noRender)
      }
    }
    return GoldenReport(entries: entries, tolerance: tolerance)
  }

  public var passed: Bool {
    entries.allSatisfy { if case .compared(let verdict) = $0.outcome { verdict.isMatch } else { false } }
  }

  /// The names whose render differs from the golden, for the difference images.
  public var changedNames: [String] {
    entries.compactMap { if case .compared(let verdict) = $0.outcome, !verdict.isMatch { $0.name } else { nil } }
  }

  /// A line per image, then a count of each outcome.
  public var summary: String {
    var matched = 0
    var changed = 0
    var new = 0
    var stale = 0
    var lines: [String] = []
    for entry in entries {
      switch entry.outcome {
      case .compared(.matches(_, let maxDifference)):
        matched += 1
        lines.append("ok       \(entry.name)" + (maxDifference > 0 ? ": channels drifted up to \(maxDifference)" : ""))
      case .compared(.differs(let pixels, let total, let maxDifference)):
        changed += 1
        lines.append(
          "CHANGED  \(entry.name): \(pixels) of \(total) pixels changed (\(Self.percent(pixels, of: total)), "
            + "\(tolerance.changedPixels) allowed), largest channel difference \(maxDifference)")
      case .compared(.sizeDiffers(let golden, let fresh)):
        changed += 1
        lines.append("SIZE     \(entry.name): golden \(golden), fresh \(fresh)")
      case .noGolden:
        new += 1
        lines.append("NEW      \(entry.name): no golden image yet")
      case .noRender:
        stale += 1
        lines.append("STALE    \(entry.name): no state renders it any more")
      }
    }
    let counts = [(matched, "matches"), (changed, "changed"), (new, "new"), (stale, "stale")]
      .filter { $0.0 > 0 }
      .map { "\($0.0) \($0.1)" }
    lines.append("\(entries.count) image\(entries.count == 1 ? "" : "s"): \(counts.joined(separator: ", ")).")
    return lines.joined(separator: "\n")
  }

  /// 1 of 16 as `6.25%`, with no trailing zeros.
  private static func percent(_ part: Int, of total: Int) -> String {
    var text = String(format: "%.2f", Double(part) / Double(total) * 100)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text + "%"
  }
}
