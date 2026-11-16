import AppKit
import SwiftUI
import HollerCore

/// Mic level for the mark while listening, fed from Blurt's capture at ~20 Hz.
@MainActor @Observable
final class LevelModel {
  var level: Float = 0
}

/// The height of the screen the note is on, which caps how tall it grows
/// before the conversation scrolls. Set when the note is shown.
@MainActor @Observable
final class NoteRoom {
  var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800
}

/// The note's shape and motion. Its colours are in `Palette`, its type in `TextStyle`.
enum NoteStyle {
  static let width: CGFloat = 385
  static let radius: CGFloat = 20
  static let barHeight: CGFloat = 34
  /// Room around the note for its shadow: 24 down, blurred 60, pulled in 18.
  /// The panel sits flush with the top and right of the screen, so the shadow
  /// is cut there, where it can't be seen.
  static let margins = EdgeInsets(top: 14, leading: 44, bottom: 72, trailing: 14)
  /// The design system's one motion: 150 ms, eased, no bounce.
  static let motion = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.15)
}

/// The floating note. The pill while you speak and Holler works; once there's
/// something to read it opens into the note: a top bar with the mark, the
/// conversation, and a footer. Light or dark with the system appearance.
struct NoteView: View {
  let controller: AssistantController
  let level: LevelModel
  var room = NoteRoom()
  var onSize: (CGSize) -> Void = { _ in }

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let form = controller.form
    let palette = Palette.of(colorScheme)
    Group {
      if form != .hidden {
        let isNote = form == .note
        let shape = RoundedRectangle(
          cornerRadius: isNote ? NoteStyle.radius : NoteStyle.barHeight / 2, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
          TopBar(controller: controller, level: level, isNote: isNote)
          if isNote {
            NoteBody(controller: controller, room: room).transition(.opacity)
          }
        }
        .background(palette.surface)
        .clipShape(shape)
        .overlay { shape.inset(by: -0.5).stroke(palette.ring, lineWidth: 1) }
        .background {
          // Hidden under the opaque note, so only its shadow shows: CSS's
          // 0 24px 60px -18px, a shadow of the note pulled in 18 on each side.
          shape.inset(by: 18).fill(.black).shadow(color: palette.shadow, radius: 30, y: 24)
        }
        // The note never takes focus, so VoiceOver reaches it only by
        // announcement or by the cursor; when it does, name the whole.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Holler note")
        .accessibilityValue(NoteSnapshot(controller).value)
      }
    }
    .fixedSize()
    .animation(NoteStyle.motion, value: form)
    .padding(NoteStyle.margins)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    // A minimum of 0 keeps the frame to the panel's size, so if the note is
    // ever taller than the screen it loses its bottom margin, not its top.
    .frame(minHeight: 0, maxHeight: .infinity, alignment: .topTrailing)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .environment(\.palette, palette)
  }
}

/// The mark on the raised surface: the whole pill, with what Holler is doing
/// beside it, or the note's top bar, where the mark is alone and the status
/// moves to the footer.
private struct TopBar: View {
  let controller: AssistantController
  let level: LevelModel
  let isNote: Bool

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 10) {
      MarkView(motion: controller.mark, level: level, color: palette.accent, height: 13)
      if !isNote, let status = controller.status {
        Text(status).textStyle(.status).foregroundStyle(palette.muted).contentTransition(.opacity)
      }
    }
    .animation(NoteStyle.motion, value: controller.status)
    .padding(.horizontal, 16)
    .frame(width: isNote ? NoteStyle.width : nil, height: NoteStyle.barHeight, alignment: .leading)
    .background(palette.raised)
    .overlay(alignment: .bottom) {
      if isNote { palette.divider.frame(height: 1) }
    }
  }
}

/// The note's body, below the top bar: the conversation and the footer.
private struct NoteBody: View {
  let controller: AssistantController
  let room: NoteRoom

  @Environment(\.palette) private var palette
  /// The conversation's natural height, to decide when it needs to scroll.
  @State private var conversationHeight: CGFloat = 0
  @State private var scroll: ScrollGeometry?

  /// Room for the conversation once the top bar, footer and margins are
  /// placed, on the screen the note is on, which needn't be the main one.
  private var maxConversationHeight: CGFloat {
    max(240, room.screenHeight - 200)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Scroll only when it has to: a ScrollView can't size to its content,
      // and offscreen preview rendering can't draw one. The top bar and
      // footer stay put.
      if conversationHeight > maxConversationHeight {
        ScrollView { conversation }
          .frame(height: maxConversationHeight)
          .defaultScrollAnchor(.bottom)
          .scrollIndicators(.never)
          .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { scroll = $1 }
          .overlay {
            // In the body's right margin, clear of the text.
            if let scroll { ScrollKnob(geometry: scroll).padding(.trailing, 9) }
          }
      } else {
        conversation
      }
      Footer(controller: controller)
    }
    .frame(width: NoteStyle.width, alignment: .leading)
  }

  private var conversation: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let notice = controller.notice {
        Text(notice).textStyle(.question).foregroundStyle(palette.muted).padding(.bottom, 14)
      }
      let shown = Array(controller.exchanges.suffix(2))
      if controller.exchanges.count > shown.count {
        Text("\(controller.exchanges.count - shown.count) earlier")
          .textStyle(.question).foregroundStyle(palette.subtle).padding(.bottom, 14)
      }
      ForEach(Array(shown.enumerated()), id: \.element.id) { index, exchange in
        if index > 0 {
          palette.divider.frame(height: 1).padding(.top, 14).padding(.bottom, 20)
        }
        ExchangeView(exchange: exchange, controller: controller)
      }
      // The agent list, where the answer will go, under the request's words
      // once the transcript is in.
      if let list = controller.agentList {
        AnswerView(answer: NoteAnswer.list(list), selectable: false)
          .padding(.top, shown.isEmpty ? 0 : 14)
          .transition(.opacity)
      }
      if case .failed(let message) = controller.phase {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .textStyle(.body)
          .foregroundStyle(palette.error)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 14)
      }
    }
    .padding(.top, 22).padding(.horizontal, 24).padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { conversationHeight = $0 }
  }
}

/// How to follow up, or what Holler is doing with the follow-up.
private struct Footer: View {
  let controller: AssistantController

  @Environment(\.palette) private var palette

  var body: some View {
    let label = controller.status ?? "Hold to follow up"
    HStack(spacing: 8) {
      // The hotkey is what you hold to ask, and are holding while it listens.
      if controller.phase == .listening || controller.phase == .ready || controller.isFailed {
        Keycap(symbol: controller.hotkey.symbol).accessibilityHidden(true)
      }
      Text(label).textStyle(.footer).foregroundStyle(palette.subtle).contentTransition(.opacity)
        .accessibilityLabel(label == "Hold to follow up" ? "Hold \(controller.hotkey.spokenName) to follow up" : label)
    }
    .animation(NoteStyle.motion, value: label)
    .frame(minHeight: 24)
    .padding(.top, 14).padding(.horizontal, 24).padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) { palette.divider.frame(height: 1) }
  }
}

/// A key on a keyboard: a 1 px border, thicker along the bottom.
private struct Keycap: View {
  let symbol: String

  @Environment(\.palette) private var palette

  var body: some View {
    Text(symbol)
      .textStyle(.keycap)
      .foregroundStyle(palette.keyText)
      .padding(.horizontal, 6).padding(.vertical, 4)
      .background(palette.keyFill, in: RoundedRectangle(cornerRadius: 3))
      .padding([.horizontal, .top], 1).padding(.bottom, 2)
      .background(palette.keyBorder, in: RoundedRectangle(cornerRadius: 4))
  }
}

/// A thin, faint scroll position marker. The system scroller, shown whenever
/// a mouse is connected, was a dark, blocky bar; scrolling works without it.
private struct ScrollKnob: View {
  let geometry: ScrollGeometry

  @Environment(\.palette) private var palette

  var body: some View {
    let visible = geometry.containerSize.height
    let total = max(geometry.contentSize.height, visible)
    let height = max(24, visible * visible / total)
    let travel = total - visible
    let progress = travel > 0 ? min(max(geometry.contentOffset.y / travel, 0), 1) : 0
    Capsule().fill(palette.subtle.opacity(0.3))
      .frame(width: 3, height: height)
      .offset(y: (visible - height) * progress)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// A request as a quoted caption, under it the answer and any confirm cards,
/// or, in a reopened note, a line where its cards were.
private struct ExchangeView: View {
  let exchange: AssistantController.Exchange
  let controller: AssistantController

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("\u{201C}\(exchange.request)\u{201D}")
        .textStyle(.question)
        .foregroundStyle(palette.subtle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("You asked: \(exchange.request)")
      if let answer = exchange.answer {
        AnswerView(answer: NoteAnswer.parse(answer)) { controller.jump(to: $0) }.padding(.top, 14)
      }
      ForEach(exchange.actions) { card in
        ConfirmCardView(card: card, controller: controller).padding(.top, 14)
      }
      if exchange.cardsLeftOut > 0 {
        Text(exchange.cardsLeftOut == 1 ? "Its card isn't shown again." : "Its \(exchange.cardsLeftOut) cards aren't shown again.")
          .textStyle(.question).foregroundStyle(palette.subtle).padding(.top, 14)
      }
    }
  }
}

/// A summary as a serif count, a sentence and one row per agent; anything
/// else as Markdown blocks. Clicking a row jumps to that agent, unless the
/// rows aren't `selectable`, as the agent list's aren't while Holler works.
struct AnswerView: View {
  let answer: NoteAnswer
  var selectable = true
  var onSelect: (AgentRow) -> Void = { _ in }

  @Environment(\.palette) private var palette

  var body: some View {
    switch answer {
    case .summary(let headline, let subline, let agents):
      VStack(alignment: .leading, spacing: 0) {
        Text(headline).textStyle(.headline).foregroundStyle(palette.ink)
          .accessibilityAddTraits(.isHeader)
        if let subline {
          inline(subline, .body).foregroundStyle(palette.muted).padding(.top, 8)
        }
        palette.divider.frame(height: 1).padding(.top, 20).padding(.bottom, 6).accessibilityHidden(true)
        ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
          AgentRowView(agent: agent, selectable: selectable) { onSelect(agent) }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    case .blocks(let blocks):
      MarkdownBlocks(blocks: blocks)
    }
  }
}

/// One agent in a summary. Clicking it jumps to the agent, so it lights up
/// under the pointer; a row that isn't `selectable` is plain.
private struct AgentRowView: View {
  let agent: AgentRow
  var selectable = true
  let onSelect: () -> Void

  @Environment(\.palette) private var palette
  @State private var isHovered = false

  var body: some View {
    if selectable {
      Button(action: onSelect, label: { row })
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(NoteStyle.motion, value: isHovered)
        .help("Show in Herdr")
        .accessibilityLabel(agent.name)
        .accessibilityValue(rowValue)
        .accessibilityHint("Shows this agent in Herdr")
    } else {
      row
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.name)
        .accessibilityValue(rowValue)
    }
  }

  private var row: some View {
    HStack(alignment: .top, spacing: 8) {
      StatusMark(state: agent.state).frame(width: 16, alignment: .leading)
      VStack(alignment: .leading, spacing: 0) {
        title.textStyle(.rowTitle)
        if !agent.update.isEmpty {
          inline(agent.update, .rowNote).foregroundStyle(palette.muted).padding(.top, 1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 7)
    // The highlight reaches a little past the text, which stays aligned
    // with the rest of the note.
    .padding(.horizontal, 8)
    .background(isHovered ? palette.raised : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .padding(.horizontal, -8)
    .contentShape(Rectangle())
  }

  /// "Needs you. Asks whether to drop the legacy /v1 routes."
  private var rowValue: String {
    let update = NoteAnnouncement.plain(agent.update)
    return update.isEmpty ? StatusMark.label(agent.state) : "\(StatusMark.label(agent.state)). \(update)"
  }

  /// "demo / " quiet, the agent's name strong.
  private var title: Text {
    let name = Text(agent.tab).font(TextStyle.rowTitle.medium).foregroundStyle(palette.ink)
    guard let workspace = agent.workspace else { return name }
    return Text("\(Text("\(workspace) / ").foregroundStyle(palette.subtle))\(name)")
  }
}

/// One accent, three marks: filled when an agent needs you, a ring while it
/// works, and a quiet dot when it's idle.
private struct StatusMark: View {
  let state: AgentRow.State

  @Environment(\.palette) private var palette

  var body: some View {
    Group {
      switch state {
      case .needsYou:
        Circle().fill(palette.accent)
      case .working:
        Circle().inset(by: 0.75).stroke(palette.accent, lineWidth: 1.5)
          .phaseAnimator([1, 0.35]) { ring, opacity in ring.opacity(opacity) } animation: { _ in
            .easeInOut(duration: 0.75)
          }
      case .idle:
        Circle().fill(palette.idleDot)
      }
    }
    .frame(width: 7, height: 7)
    // Centred on the title's first line.
    .padding(.top, 5.5)
    .accessibilityLabel(Self.label(state))
  }

  static func label(_ state: AgentRow.State) -> String {
    switch state {
    case .needsYou: "Needs you"
    case .working: "Working"
    case .idle: "Idle"
    }
  }
}

/// Paragraphs, bullets and headings, each with inline Markdown.
struct MarkdownBlocks: View {
  let blocks: [NoteBlock]

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .paragraph(let text):
          inline(text, .body)
        case .heading(let text):
          inline(text, .bodyMedium)
        case .bullet(let text):
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(palette.subtle).accessibilityHidden(true)
            inline(text, .body)
          }
        case .subBullet(let text):
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("◦").foregroundStyle(palette.subtle).accessibilityHidden(true)
            inline(text, .body)
          }
          .padding(.leading, 16)
        }
      }
    }
    .foregroundStyle(palette.ink)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// Inline Markdown in a text style, with bold at weight 500, as the design
/// sets agent names.
private func inline(_ text: String, _ style: TextStyle) -> some View {
  let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
  var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
  let strong = attributed.runs
    .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
    .map(\.range)
  for range in strong {
    attributed[range].inlinePresentationIntent?.remove(.stronglyEmphasized)
    attributed[range].swiftUI.font = style.medium
  }
  // An answer is shaped by what's on agents' screens, so a link in it isn't
  // one to click from here: its words show as plain text.
  for range in attributed.runs.filter({ $0.link != nil }).map(\.range) {
    attributed[range].link = nil
  }
  return Text(attributed).textStyle(style)
}

/// A proposed action on a card a step darker than the note. Nothing happens
/// until you click Send, Start, Close or Interrupt, or press Return while the
/// newest card's button shows ↩.
private struct ConfirmCardView: View {
  let card: AssistantController.Card
  let controller: AssistantController

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      layout(card.content)
      status.padding(.top, 2)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.divider) }
    // One element per card, its buttons still inside it, so VoiceOver says
    // what the card does before it reaches Send and Cancel.
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Confirm card: \(card.content.verb) \(card.content.target)")
    .accessibilityValue(cardValue)
  }

  /// What the card holds and where it is: the body for a waiting card, else its status.
  private var cardValue: String {
    switch card.status {
    case .waiting(let reason): NoteAnnouncement.cardLine(card.content, waitsBecause: reason, returnConfirms: returnConfirms)
    case .countingDown(let seconds): NoteAnnouncement.countdownLine(card.content, seconds: seconds, returnRuns: returnConfirms)
    case .paused: NoteAnnouncement.pausedLine(card.content, returnRuns: returnConfirms)
    case .busy: words.busy
    case .replaced: "Replaced by the card below."
    default: NoteAnnouncement.statusLine(card.content, card.status) ?? ""
    }
  }

  /// Every kind's card from its content: the heading, any subtitle, the body,
  /// detail rows and warnings.
  @ViewBuilder private func layout(_ content: ConfirmCard) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      heading(icon: Self.icon(content.kind), verb: content.verb, target: content.target)
      if let subtitle = content.subtitle {
        Text(subtitle)
          .font(.system(size: 11).monospaced()).foregroundStyle(palette.subtle)
          .lineLimit(1).truncationMode(.middle)
      }
    }
    if let body = content.body {
      Text(body).textStyle(.body).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
    } else if let placeholder = content.placeholder {
      Text(placeholder).textStyle(.body).foregroundStyle(palette.muted)
    }
    ForEach(Array(content.details.enumerated()), id: \.offset) { _, detail in
      VStack(alignment: .leading, spacing: 2) {
        Text(detail.label).font(.system(size: 11).monospaced()).foregroundStyle(palette.subtle)
        Text(detail.text ?? detail.placeholder ?? "").textStyle(.body)
          .foregroundStyle(detail.text == nil ? palette.muted : palette.ink)
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      }
    }
    ForEach(content.warnings, id: \.self) { warning in
      Label(warning, systemImage: "exclamationmark.triangle.fill")
        .textStyle(.body).foregroundStyle(palette.error).fixedSize(horizontal: false, vertical: true)
    }
  }

  private static func icon(_ kind: ConfirmCard.Kind) -> String {
    switch kind {
    case .send: "paperplane.fill"
    case .start: "plus.rectangle.on.rectangle"
    case .close: "xmark.rectangle"
    case .interrupt: "stop.circle"
    }
  }

  private func heading(icon: String, verb: String, target: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.accent)
        .accessibilityHidden(true)
      Text("\(Text("\(verb) ").foregroundStyle(palette.subtle))\(Text(target).font(TextStyle.rowTitle.medium).foregroundStyle(palette.ink))")
        .textStyle(.rowTitle)
    }
  }

  /// The card's wording for its action: button, in progress, done, cancelled, failed.
  private var words: ConfirmCard.Words { card.content.words }

  /// Whether Return confirms this card: it's the newest waiting and Holler
  /// holds the keyboard.
  private var returnConfirms: Bool { controller.holdsKeyboard && controller.newestWaitingAction == card.id }

  @ViewBuilder private var status: some View {
    switch card.status {
    case .waiting(let reason):
      VStack(alignment: .leading, spacing: 10) {
        // Why it waits when it might have counted down, in one quiet line:
        // "api is working, so this waits for you."
        if let reason {
          Text(reason).textStyle(.body).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          Button(returnConfirms ? "↩ \(words.button)" : words.button) { controller.confirm(card.id) }
            .buttonStyle(NoteButtonStyle(prominent: true))
            .accessibilityLabel(words.button)
            .accessibilityHint(returnConfirms ? "Return does this too" : "")
          Button("Cancel") { controller.cancel(card.id) }
            .buttonStyle(NoteButtonStyle(prominent: false))
        }
      }
    case .countingDown(let seconds):
      // "Sending in 3… 2… 1…", then the buttons: Return runs it at once,
      // Cancel stops it. No progress bar.
      HStack(spacing: 8) {
        Text("\(words.countdown) \(seconds)…").textStyle(.body).foregroundStyle(palette.muted)
          .contentTransition(.numericText(countsDown: true))
          .animation(NoteStyle.motion, value: seconds)
          .accessibilityHidden(true)
        countdownButtons
      }
    case .paused:
      // Held for your follow-up: the line goes above the same buttons, since
      // it's too long to sit beside them.
      VStack(alignment: .leading, spacing: 10) {
        Text(NoteAnnouncement.paused).textStyle(.body).foregroundStyle(palette.muted).accessibilityHidden(true)
        HStack(spacing: 8) { countdownButtons }
      }
    case .busy:
      Text(words.busy).textStyle(.body).foregroundStyle(palette.muted)
    case .done:
      Label {
        Text(words.done).font(TextStyle.body.medium).foregroundStyle(palette.ink)
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
      }
      .textStyle(.body)
    case .cancelled, .withdrawn:
      Label(words.cancelled, systemImage: "xmark.circle")
        .textStyle(.body).foregroundStyle(palette.muted)
    case .replaced:
      Label("Replaced by the card below.", systemImage: "arrow.down.circle")
        .textStyle(.body).foregroundStyle(palette.muted)
    case .failed(let message):
      Label("\(words.failed): \(message)", systemImage: "exclamationmark.triangle.fill")
        .textStyle(.body)
        .foregroundStyle(palette.error)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// A counting or paused card's buttons: Return runs it at once, Cancel
  /// stops it.
  @ViewBuilder private var countdownButtons: some View {
    Button(returnConfirms ? "↩ \(words.runNow)" : words.runNow) { controller.confirm(card.id) }
      .buttonStyle(NoteButtonStyle(prominent: true))
      .accessibilityLabel(words.runNow)
      .accessibilityHint(returnConfirms ? "Return does this too" : "")
    Button("Cancel") { controller.cancel(card.id) }
      .buttonStyle(NoteButtonStyle(prominent: false))
  }
}

/// The design system's button: a 4 px rectangle, never a pill, with a short
/// all-caps label. Indigo for the action, outlined for Cancel.
private struct NoteButtonStyle: ButtonStyle {
  let prominent: Bool

  @Environment(\.palette) private var palette

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
    configuration.label
      .textStyle(.button)
      .textCase(.uppercase)
      .foregroundStyle(prominent ? palette.onAccent : palette.ink)
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(prominent ? palette.accent : palette.surface, in: shape)
      .overlay { if !prominent { shape.strokeBorder(palette.keyBorder) } }
      .contentShape(shape)
      .opacity(configuration.isPressed ? 0.75 : 1)
      .animation(NoteStyle.motion, value: configuration.isPressed)
  }
}

extension AssistantController {
  var isFailed: Bool {
    if case .failed = phase { true } else { false }
  }
}
