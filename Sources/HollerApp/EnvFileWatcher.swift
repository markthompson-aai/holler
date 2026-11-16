import Foundation

/// Watches the settings file and calls `onChange` once a save has settled.
///
/// Many editors save by writing a new file and renaming it over the old one,
/// which leaves a watch on the old file seeing nothing more. So after a
/// delete or rename the watch moves to whatever file is at the path now,
/// looking again every second while there is none.
@MainActor
final class EnvFileWatcher {
  /// One save can arrive as several events (write, extend, rename, attrib).
  private static let settle: Duration = .milliseconds(300)
  private static let retry: Duration = .seconds(1)

  private let url: URL
  private let onChange: @MainActor () -> Void
  private var source: (any DispatchSourceFileSystemObject)?
  private var pending: Task<Void, Never>?
  private var retrying: Task<Void, Never>?

  init(url: URL, onChange: @escaping @MainActor () -> Void) {
    self.url = url
    self.onChange = onChange
  }

  func start() {
    arm()
  }

  func stop() {
    source?.cancel()
    source = nil
    pending?.cancel()
    retrying?.cancel()
  }

  /// Watches the file now at the path. Returns false when there is none yet,
  /// and looks again shortly.
  @discardableResult
  private func arm() -> Bool {
    source?.cancel()
    source = nil
    retrying?.cancel()
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else {
      retrying = Task { [weak self] in
        try? await Task.sleep(for: Self.retry)
        guard !Task.isCancelled, let self else { return }
        // The file is back: what it says now may be new.
        if arm() { changed() }
      }
      return false
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.handleEvent() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    self.source = source
    return true
  }

  private func handleEvent() {
    guard let source else { return }
    if !source.data.isDisjoint(with: [.delete, .rename]) { arm() }
    changed()
  }

  /// Calls `onChange` once the events of one save have stopped coming.
  private func changed() {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: Self.settle)
      guard !Task.isCancelled, let self else { return }
      onChange()
    }
  }
}
