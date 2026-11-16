import Foundation

/// More of some agents' output than the recent output sent with the request.
/// Panes are read in parallel and reported in the order asked for.
struct ReadAgentsTool: AssistantTool {
  static let defaultLines = 150
  /// Per pane: enough that Herdr's own limit is the only cut. Herdr serves at
  /// most 1,000 unwrapped lines however many are asked for, and the longest
  /// such read measured on 2026-11-04 was 110,000 characters, so a whole
  /// scrollback always fits; the worst case is about 50,000 tokens, paid only
  /// when the model asks for a full read. The recent output sent with a
  /// request is cut at a few thousand characters.
  static let maxCharacters = 200_000

  var isRead: Bool { true }

  var definition: ToolDefinition {
    ToolDefinition(
      name: "read_agents",
      description: """
        Read more of one or more agents' terminal output than the recent output already \
        included with the request. Read every agent you need in one call. A pane's text starts \
        with a bracketed line only when something is missing: "[earlier output left out: about N \
        characters]" when the read was cut, or "[visible screen only: ...]" for a working agent, \
        whose earlier output can't be read until it stops.
        """,
      parameters: [
        "type": "object",
        "properties": [
          "pane_ids": [
            "type": "array",
            "items": ["type": "string", "pattern": .string(AssistantTools.paneIdPattern)],
            "description": "Pane ids from the agent list, e.g. [\"w6:p3\"].",
          ],
          "lines": [
            "type": "integer",
            "description": .string(
              "Recent lines per pane. Default \(Self.defaultLines); up to "
                + "\(HerdrClient.maxReadLines.formatted(.number.locale(Locale(identifier: "en_US")))) for the whole output of one agent."),
          ],
        ],
        "required": ["pane_ids"],
      ]
    )
  }

  /// What a result says went wrong, one line per pane, for the turn log:
  /// a pane that failed to read, or one that came back behind a marker
  /// (screen only, timed out, or cut). Empty when every pane read in full.
  static func problems(in result: String) -> [String] {
    var problems: [String] = []
    for match in result.matches(of: /<pane id="([^"]+)" error="([^"]*)"/) {
      problems.append("pane=\(match.output.1) error=\(match.output.2)")
    }
    for match in result.matches(of: /<pane id="([^"]+)" status="[^"]*">\n(\[[^\n]*\])/) {
      problems.append("pane=\(match.output.1) \(match.output.2)")
    }
    return problems
  }

  func run(_ arguments: JSONValue, _ context: ToolContext) async throws -> ToolResult {
    guard case .array(let ids)? = arguments["pane_ids"], !ids.isEmpty else { throw ToolError("pane_ids is required") }
    let lines = arguments["lines"]?.intValue ?? Self.defaultLines
    let paneIds = ids.compactMap(\.stringValue)
    let herdr = context.herdr
    let outputs = await withTaskGroup(of: PaneRead.self) { group in
      for paneId in paneIds {
        group.addTask {
          do {
            let read = try await herdr.read(paneId: paneId, lines: lines, maxCharacters: Self.maxCharacters)
            return PaneRead(paneId: paneId, agent: read.agent, text: read.text, error: nil)
          } catch {
            return PaneRead(paneId: paneId, agent: nil, text: nil, error: "\(error)")
          }
        }
      }
      var collected: [String: PaneRead] = [:]
      for await read in group { collected[read.paneId] = read }
      return collected
    }
    let read = outputs.values.compactMap(\.agent)
    context.onEvent(.reading(read))
    return .text(
      paneIds.map { paneId in
        switch outputs[paneId] {
        case let read? where read.agent != nil:
          "<pane id=\"\(paneId)\" status=\"\(read.agent!.status)\">\n\(read.text ?? "")\n</pane>"
        case let read?:
          "<pane id=\"\(paneId)\" error=\"\(read.error ?? "failed")\" />"
        case nil:
          "<pane id=\"\(paneId)\" error=\"not read\" />"
        }
      }.joined(separator: "\n\n"), about: read.map(\.paneId))
  }

  /// One pane's read, as a plain struct on purpose. With the element typed as
  /// `(String, Result<(agent: HerdrAgent, text: String), any Error>)`, the
  /// optimised build (Swift 6.3.3, `-O`) drops every child's result on the
  /// floor: `for await` over the group ends at once with nothing collected,
  /// so every pane came back "not read" in the app while the debug CLI read
  /// it in full. A struct element collects fine in both builds.
  struct PaneRead: Sendable {
    let paneId: String
    let agent: HerdrAgent?
    let text: String?
    let error: String?
  }
}
