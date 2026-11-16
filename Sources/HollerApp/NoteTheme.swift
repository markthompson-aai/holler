import AppKit
import SwiftUI

/// The note's colours, one set per macOS appearance. Every surface is opaque,
/// so what's behind the note never changes how it reads. From AssemblyAI's
/// design system: warm cream and warm off-black, with one indigo accent.
struct Palette: Sendable {
  /// The note's body.
  var surface: Color
  /// The top bar, the pill and confirm cards: a step darker than the body.
  var raised: Color
  var divider: Color
  var ink: Color
  /// Agent notes and the sentence under the headline.
  var muted: Color
  /// The question, workspace names and the footer.
  var subtle: Color
  /// The mark, and the status of agents that need you or are working.
  var accent: Color
  /// Text on the accent: the Send button's label.
  var onAccent: Color
  var idleDot: Color
  var keyFill: Color
  var keyBorder: Color
  var keyText: Color
  /// Not in the design system, which has no error colour: a muted warm red.
  var error: Color
  /// The hairline just outside the note, and its shadow.
  var ring: Color
  var shadow: Color

  static let light = Palette(
    surface: hex(0xFBF8F2), raised: hex(0xF4F1EB), divider: hex(0xDCD7CC),
    ink: hex(0x1B1A18), muted: hex(0x57534B), subtle: hex(0x6F6A60),
    accent: hex(0x3F2BC1), onAccent: hex(0xFBF8F2), idleDot: hex(0xD6D1C7),
    keyFill: hex(0xFFFFFF), keyBorder: hex(0xB6B0A4), keyText: hex(0x57534B),
    error: hex(0xB3402A),
    ring: hex(0x14120C).opacity(0.12), shadow: hex(0x14120C).opacity(0.35))

  static let dark = Palette(
    surface: hex(0x131210), raised: hex(0x1B1A18), divider: hex(0x2A2924),
    ink: hex(0xF2EFE7), muted: hex(0xB6B0A4), subtle: hex(0x8A847A),
    accent: hex(0xA99CFF), onAccent: hex(0x131210), idleDot: hex(0x3D3A35),
    keyFill: hex(0x1B1A18), keyBorder: hex(0x3D3A35), keyText: hex(0xB6B0A4),
    error: hex(0xF0957E),
    ring: .white.opacity(0.08), shadow: .black.opacity(0.6))

  static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .dark : .light }

  private static func hex(_ value: UInt32) -> Color {
    Color(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

// Not `@Entry`: the Command Line Tools ship without SwiftUI's macro plugin.
private struct PaletteKey: EnvironmentKey {
  static let defaultValue = Palette.light
}

extension EnvironmentValues {
  var palette: Palette {
    get { self[PaletteKey.self] }
    set { self[PaletteKey.self] = newValue }
  }
}

/// The note's two typefaces: Source Serif 4 for the summary headline, and
/// AssemblyAI's Monument Grotesk for everything else when it's installed,
/// otherwise the system font.
enum Fonts {
  /// Registers the bundled serif for this process. Call once at launch,
  /// before anything is drawn.
  static func register() {
    guard let url = Bundle.main.url(forResource: "SourceSerif4", withExtension: "ttf") else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }

  /// Source Serif 4 at the optical size for its point size, as browsers set
  /// it; Charter if the font isn't bundled.
  static func serif(_ size: CGFloat) -> NSFont {
    let axes: [Int: CGFloat] = [opticalSizeAxis: size, weightAxis: 400]
    let descriptor = NSFontDescriptor(fontAttributes: [.family: "Source Serif 4", .variation: axes])
    if let font = NSFont(descriptor: descriptor, size: size), font.familyName == "Source Serif 4" { return font }
    return NSFont(name: "Charter", size: size) ?? .systemFont(ofSize: size)
  }

  static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    if let family = brandSans {
      let descriptor = NSFontDescriptor(fontAttributes: [
        .family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
      ])
      if let font = NSFont(descriptor: descriptor, size: size) { return font }
    }
    return .systemFont(ofSize: size, weight: weight)
  }

  /// The licensed brand face isn't bundled; use it only when it's installed.
  private static let brandSans = ["ABC Monument Grotesk", "Monument Grotesk"].first {
    NSFontManager.shared.availableFontFamilies.contains($0)
  }

  // OpenType variation axis tags: 'opsz' and 'wght'.
  private static let opticalSizeAxis = 0x6F70_737A
  private static let weightAxis = 0x7767_6874
}

/// A text style from the design: a font and the line height it sits in.
/// NSFont is immutable, so a style can be shared.
struct TextStyle: @unchecked Sendable {
  let font: NSFont
  let lineHeight: CGFloat
  var tracking: CGFloat = 0

  /// The quoted question.
  static let question = sans(12, lineHeight: 18)
  /// The summary's count, the one serif line.
  static let headline = TextStyle(font: Fonts.serif(20), lineHeight: 26, tracking: -0.2)
  /// The sentence under the headline, answers and confirm cards.
  static let body = sans(13, lineHeight: 20)
  static let bodyMedium = sans(13, .medium, lineHeight: 20)
  static let rowTitle = sans(12.5, lineHeight: 18)
  static let rowNote = sans(12.5, lineHeight: 18)
  static let status = sans(12.5, .medium, lineHeight: 18)
  static let footer = sans(11.5, lineHeight: 16)
  static let keycap = sans(10, .medium, lineHeight: 13)
  static let button = TextStyle(font: Fonts.sans(11, .medium), lineHeight: 14, tracking: 0.6)

  private static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular, lineHeight: CGFloat) -> TextStyle {
    TextStyle(font: Fonts.sans(size, weight), lineHeight: lineHeight)
  }

  /// The sans at this size at weight 500, for names and bold runs.
  var medium: Font { Font(Fonts.sans(font.pointSize, .medium)) }
}

extension View {
  /// Sets the style's font and spaces its lines as CSS does: the room the
  /// line height adds goes between lines and half above and below the text.
  nonisolated func textStyle(_ style: TextStyle) -> some View {
    let font = style.font
    let extra = max(0, style.lineHeight - (font.ascender - font.descender + font.leading))
    return self.font(Font(font))
      .tracking(style.tracking)
      .lineSpacing(extra)
      .padding(.vertical, extra / 2)
  }
}
