import Foundation

/// Who follows one kind of value an actor gives out: a stream per follower,
/// each told of every value from when it joined until it stops listening.
/// The actor keeps one of these per kind and yields to it.
struct Followers<Element: Sendable>: Sendable {
  private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

  /// A new follower's stream, with `first` on it at once if given. `forget`
  /// runs, from any thread, once the follower stops listening, for the actor
  /// to call `forget(_:)` with the id.
  mutating func add(first: Element? = nil, onEnd forget: @escaping @Sendable (UUID) -> Void) -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
    let id = UUID()
    continuations[id] = continuation
    continuation.onTermination = { _ in forget(id) }
    if let first { continuation.yield(first) }
    return stream
  }

  mutating func forget(_ id: UUID) {
    continuations[id] = nil
  }

  /// Tells every follower.
  func yield(_ value: Element) {
    for continuation in continuations.values { continuation.yield(value) }
  }
}
