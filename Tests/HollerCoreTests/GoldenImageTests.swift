import Testing

@testable import HollerCore

@Suite struct GoldenImageTests {
  static let grey = Pixel(200, 200, 200, 255)

  /// A 4×4 grey image, with `changes` painted over single pixels.
  static func image(width: Int = 4, height: Int = 4, changes: [(x: Int, y: Int, Pixel)] = []) -> PixelImage {
    var image = PixelImage(width: width, height: height, fill: grey)
    for change in changes { image[change.x, change.y] = change.2 }
    return image
  }

  @Test func anImageIsFilledAndAddressedByPixel() {
    var image = Self.image(width: 3, height: 2)
    #expect(image.rgba.count == 24)
    #expect(image[2, 1] == Self.grey)
    image[2, 1] = Pixel(1, 2, 3, 4)
    #expect(image[2, 1] == Pixel(1, 2, 3, 4))
    #expect(image[5] == Pixel(1, 2, 3, 4))
    #expect(Array(image.rgba[20...]) == [1, 2, 3, 4])
  }

  @Test func identicalImagesMatch() {
    let a = Self.image()
    #expect(GoldenImage.compare(golden: a, fresh: a) == .matches(changedPixels: 0, maxChannelDifference: 0))
  }

  @Test func aChannelWithinToleranceIsNotAChange() {
    let golden = Self.image()
    let fresh = Self.image(changes: [(1, 1, Pixel(203, 200, 197, 255))])
    #expect(
      GoldenImage.compare(golden: golden, fresh: fresh, tolerance: .init(channel: 3, changedPixels: 0))
        == .matches(changedPixels: 0, maxChannelDifference: 3))
  }

  @Test func aPixelPastToleranceCountsAndTheAllowanceDecides() {
    let golden = Self.image()
    let fresh = Self.image(changes: [(1, 1, Pixel(255, 200, 200, 255)), (2, 3, Pixel(200, 200, 100, 255))])
    #expect(
      GoldenImage.compare(golden: golden, fresh: fresh, tolerance: .init(channel: 3, changedPixels: 1))
        == .differs(changedPixels: 2, of: 16, maxChannelDifference: 100))
    #expect(
      GoldenImage.compare(golden: golden, fresh: fresh, tolerance: .init(channel: 3, changedPixels: 2))
        == .matches(changedPixels: 2, maxChannelDifference: 100))
  }

  @Test func alphaCountsAsAChannel() {
    let golden = Self.image()
    let fresh = Self.image(changes: [(0, 0, Pixel(200, 200, 200, 0))])
    #expect(
      GoldenImage.compare(golden: golden, fresh: fresh, tolerance: .init(channel: 3, changedPixels: 0))
        == .differs(changedPixels: 1, of: 16, maxChannelDifference: 255))
  }

  @Test func aDifferentSizeFailsBeforeAnyPixelIsRead() {
    let golden = Self.image()
    let fresh = Self.image(width: 4, height: 5)
    #expect(
      GoldenImage.compare(golden: golden, fresh: fresh)
        == .sizeDiffers(golden: PixelSize(width: 4, height: 4), fresh: PixelSize(width: 4, height: 5)))
  }

  @Test func theDefaultToleranceLetsAChannelDriftButNoPixelChange() {
    let tolerance = GoldenTolerance.default
    #expect(tolerance.channel == 3)
    #expect(tolerance.changedPixels == 0)
  }

  @Test func theDifferenceImagePaintsChangedPixelsRedOverAFadedFresh() {
    let golden = Self.image()
    let fresh = Self.image(changes: [(1, 1, Pixel(0, 0, 0, 255))])
    let diff = GoldenImage.difference(golden: golden, fresh: fresh)
    #expect(diff.size == PixelSize(width: 4, height: 4))
    #expect(diff[1, 1] == Pixel(255, 0, 0, 255))
    // Unchanged pixels fade half-way to white so the red stands out: 200 → 227.
    #expect(diff[0, 0] == Pixel(227, 227, 227, 255))
  }

  @Test func theDifferenceImageCoversBothSizesAndMarksWhatOnlyOneHas() {
    let golden = Self.image(width: 2, height: 2)
    let fresh = Self.image(width: 3, height: 2)
    let diff = GoldenImage.difference(golden: golden, fresh: fresh)
    #expect(diff.size == PixelSize(width: 3, height: 2))
    #expect(diff[2, 0] == Pixel(255, 0, 0, 255))
    #expect(diff[0, 0] == Pixel(227, 227, 227, 255))
  }

  @Test func aReportReconcilesNamesAndSortsThem() {
    let same = Self.image()
    let other = Self.image(changes: [(0, 0, Pixel(0, 0, 0, 255))])
    let report = GoldenReport.compare(
      goldens: ["b-dark": same, "a-light": same, "stale-light": same],
      fresh: ["b-dark": other, "a-light": same, "new-dark": same],
      tolerance: .init(channel: 3, changedPixels: 0))
    #expect(report.entries.map(\.name) == ["a-light", "b-dark", "new-dark", "stale-light"])
    #expect(report.entries[0].outcome == .compared(.matches(changedPixels: 0, maxChannelDifference: 0)))
    #expect(report.entries[1].outcome == .compared(.differs(changedPixels: 1, of: 16, maxChannelDifference: 200)))
    #expect(report.entries[2].outcome == .noGolden)
    #expect(report.entries[3].outcome == .noRender)
    #expect(!report.passed)
    #expect(report.changedNames == ["b-dark"])
  }

  @Test func aReportPassesWhenEveryImageMatches() {
    let same = Self.image()
    let report = GoldenReport.compare(goldens: ["a": same], fresh: ["a": same])
    #expect(report.passed)
    #expect(report.changedNames.isEmpty)
    #expect(report.summary == "ok       a\n1 image: 1 matches.")
  }

  @Test func aReportSaysWhatEachOutcomeMeans() {
    let same = Self.image()
    let drifted = Self.image(changes: [(0, 0, Pixel(202, 200, 200, 255))])
    let other = Self.image(changes: [(0, 0, Pixel(0, 0, 0, 255))])
    let taller = Self.image(width: 4, height: 6)
    let report = GoldenReport.compare(
      goldens: ["a": same, "a2": same, "b": same, "c": same, "d": same],
      fresh: ["a": same, "a2": drifted, "b": other, "c": taller, "e": same],
      tolerance: .init(channel: 3, changedPixels: 0))
    #expect(
      report.summary == """
        ok       a
        ok       a2: channels drifted up to 2
        CHANGED  b: 1 of 16 pixels changed (6.25%, 0 allowed), largest channel difference 200
        SIZE     c: golden 4×4, fresh 4×6
        STALE    d: no state renders it any more
        NEW      e: no golden image yet
        6 images: 2 matches, 2 changed, 1 new, 1 stale.
        """)
  }
}
