import AppKit
import HollerCore

/// `Holler --check-previews <goldens> <output>`: renders every note state as
/// `--render-previews` does, compares each PNG with the golden image of the
/// same name, and says what changed. The fresh renders go to `output/fresh`,
/// and each change gets a `<name>-diff.png` beside them: red where it moved.
@MainActor
enum GoldenCheck {
  static func run(goldens goldensDirectory: URL, output: URL) -> Bool {
    clearLastRun(in: output)
    let freshDirectory = output.appendingPathComponent("fresh")
    let rendered = PreviewRenderer.renderAll(to: freshDirectory)
    guard rendered.count == PreviewRenderer.renderCount else {
      print("only \(rendered.count) of \(PreviewRenderer.renderCount) states rendered; nothing compared")
      return false
    }
    let goldens = images(in: goldensDirectory)
    guard !goldens.isEmpty else {
      print("no golden images in \(goldensDirectory.path); record them with scripts/check-previews.sh --update")
      return false
    }

    let fresh = images(in: freshDirectory)
    let report = GoldenReport.compare(goldens: goldens, fresh: fresh)
    print(report.summary)
    for name in report.changedNames {
      guard let golden = goldens[name], let render = fresh[name] else { continue }
      let diff = GoldenImage.difference(golden: golden, fresh: render)
      try? diff.pngData()?.write(to: output.appendingPathComponent("\(name)-diff.png"))
    }
    if !report.passed {
      print("Fresh renders and difference images are in \(output.path).")
      print("If the change is meant, re-record the golden images with scripts/check-previews.sh --update.")
    }
    return report.passed
  }

  /// Removes only what a run of this check writes: the fresh renders and the
  /// difference images. Anything else in the output directory is left alone.
  private static func clearLastRun(in output: URL) {
    let files = FileManager.default
    try? files.removeItem(at: output.appendingPathComponent("fresh"))
    for file in (try? files.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
    where file.lastPathComponent.hasSuffix("-diff.png") {
      try? files.removeItem(at: file)
    }
  }

  /// Every PNG in the directory, keyed by its name without the extension.
  private static func images(in directory: URL) -> [String: PixelImage] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    var images: [String: PixelImage] = [:]
    for file in files where file.pathExtension == "png" {
      if let image = PixelImage(pngAt: file) { images[file.deletingPathExtension().lastPathComponent] = image }
    }
    return images
  }
}
