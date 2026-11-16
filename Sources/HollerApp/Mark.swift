import AppKit
import SwiftUI
import HollerCore

private struct MarkFrozenAtKey: EnvironmentKey {
  static let defaultValue: Date? = nil
}

extension EnvironmentValues {
  /// A fixed moment for the mark's motion, so a render of the same state
  /// comes out the same every time, whatever the Reduce Motion setting.
  /// Nil, the default, lets it follow the clock.
  var markFrozenAt: Date? {
    get { self[MarkFrozenAtKey.self] }
    set { self[MarkFrozenAtKey.self] = newValue }
  }
}

/// The mark: five rounded bars. Still as a logo, moving with your voice
/// while listening, rippling while Holler works. With Reduce Motion on it
/// holds still and breathes instead: the logo's shape while listening, a
/// level row while working.
struct MarkView: View {
  let motion: AssistantController.MarkMotion
  let level: LevelModel
  let color: Color
  var height: CGFloat = 16

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.markFrozenAt) private var frozenAt

  /// Bar heights at rest, as fractions of the mark's height: 6, 12, 16, 10 and 5 of 16.
  static let rest: [CGFloat] = [6, 12, 16, 10, 5].map { $0 / 16 }
  /// A bar's width, and the gap between bars, as fractions of the mark's height: 2.5 of 16.
  static let barWidth: CGFloat = 2.5 / 16
  static let gap: CGFloat = 2.5 / 16

  var body: some View {
    Group {
      if let frozenAt {
        bars(fractions(at: frozenAt.timeIntervalSinceReferenceDate))
      } else if reduceMotion, motion != .still {
        // A slow breath of opacity, nothing moves.
        bars(Self.stillFractions(motion))
          .phaseAnimator([1.0, 0.45]) { mark, opacity in mark.opacity(opacity) } animation: { _ in
            .easeInOut(duration: 1.4)
          }
      } else {
        TimelineView(.animation(paused: motion == .still)) { timeline in
          bars(fractions(at: timeline.date.timeIntervalSinceReferenceDate))
        }
      }
    }
    .accessibilityHidden(true)
  }

  private func fractions(at t: Double) -> [CGFloat] {
    let level = CGFloat(min(max(level.level, 0), 1))
    return (0..<5).map { fraction($0, t, level) }
  }

  private func bars(_ fractions: [CGFloat]) -> some View {
    let bar = height * Self.barWidth
    return HStack(spacing: height * Self.gap) {
      ForEach(0..<5, id: \.self) { i in
        Capsule()
          .fill(color)
          .frame(width: bar, height: max(bar, height * fractions[i]))
      }
    }
    .frame(height: height)
  }

  /// Where the bars hold with Reduce Motion on: the logo at rest and while
  /// listening (the breath says the mic is live), a level row while working.
  static func stillFractions(_ motion: AssistantController.MarkMotion) -> [CGFloat] {
    switch motion {
    case .still, .listening: rest
    case .working: Array(repeating: 0.55, count: 5)
    }
  }

  private func fraction(_ i: Int, _ t: Double, _ level: CGFloat) -> CGFloat {
    let rest = Self.rest[i]
    switch motion {
    case .still:
      return rest
    case .listening:
      // An equaliser: each bar follows your voice, with a little flutter of its own.
      let flutter = 0.8 + 0.2 * sin(t * 13 + Double(i) * 1.7)
      return 0.2 + 0.8 * level * rest * flutter
    case .working:
      // A ripple running across the bars.
      return 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 6 - Double(i) * 0.9))
    }
  }

  /// The mark at rest for the menu bar, as a template so it follows the menu
  /// bar's colour. With agents `needingYou`, their count follows the mark in
  /// the menu bar's font; with none, the mark alone.
  static func menuBarImage(needingYou count: Int = 0) -> NSImage {
    let height: CGFloat = 14
    let (bar, gap) = (height * barWidth, height * Self.gap)
    let markWidth = 5 * bar + 4 * gap
    let font = NSFont.menuBarFont(ofSize: 0)
    let numeral =
      count > 0 ? NSAttributedString(string: "\(count)", attributes: [.font: font, .foregroundColor: NSColor.black]) : nil
    // The space between the mark and the numeral: a little more than between bars.
    let numeralGap = gap + 1
    let numeralWidth = numeral.map { $0.size().width + numeralGap } ?? 0
    let size = NSSize(width: (markWidth + numeralWidth).rounded(.up), height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      let markStart = rect.midX - (markWidth + numeralWidth) / 2
      var x = markStart
      NSColor.black.setFill()
      for rest in rest {
        let barHeight = height * rest
        NSBezierPath(
          roundedRect: NSRect(x: x, y: rect.midY - barHeight / 2, width: bar, height: barHeight),
          xRadius: bar / 2, yRadius: bar / 2
        ).fill()
        x += bar + gap
      }
      if let numeral {
        // Digits sit between the baseline and the cap height, so centre that
        // span on the bars, not the line box with its descender room.
        let baseline = rect.midY - font.capHeight / 2
        numeral.draw(at: NSPoint(x: markStart + markWidth + numeralGap, y: baseline + font.descender))
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription =
      switch count {
      case 0: "Holler"
      case 1: "Holler, 1 agent needs you"
      default: "Holler, \(count) agents need you"
      }
    return image
  }
}
