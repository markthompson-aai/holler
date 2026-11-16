import AppKit
import HollerCore

extension PixelImage {
  /// Decodes a PNG through one fixed pixel format, so a golden image and a
  /// fresh render are compared on equal terms. The bytes are premultiplied
  /// RGBA, which is the same as straight where the image is opaque, as every
  /// render is.
  init?(pngAt file: URL) {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    let (width, height) = (image.width, image.height)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: Self.colorSpace, bitmapInfo: Self.bitmapInfo.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    self.init(width: width, height: height, rgba: rgba)
  }

  func pngData() -> Data? {
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: Self.colorSpace, bitmapInfo: Self.bitmapInfo, provider: provider, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let bitmapInfo = CGBitmapInfo(
    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
}
