import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscale and re-encode for images that are too big for where they are headed
/// (`apps/web/src/lib/imageCompression.ts`), with ImageIO instead of canvas. Two consumers share the
/// pipeline: the composer shrinks pasted or dropped images to the provider's wire cap instead of
/// refusing them, and the prompt stash fits images into its per-entry budget. HEIC and HEIF photos
/// become JPEG first because providers cannot read them.
public enum ImageCompression {
  /// Longest edge kept when an image has to be re-encoded.
  static let maxDimension = 2048
  /// Ceiling on the source handed to the decoder; beyond it decoding itself is the risk.
  public static let maxCompressibleSourceBytes = 50 * 1024 * 1024
  static let maxHeicDecodePixels = 64_000_000
  static let qualitySteps: [Double] = [0.92, 0.85, 0.78, 0.68]
  static let fallbackScaleSteps: [Double] = [0.75, 0.55]
  /// Base64 budget for a single stashed image.
  public static let maxStashImageDataURLChars = 1_300_000

  public enum Failure: String, Sendable, Error { case tooLarge = "too-large", unreadable }

  public struct Output: Sendable {
    public var data: Data
    public var mimeType: String
    public var name: String
    public var recompressed: Bool
    public var pixelSize: CGSize?
  }

  /// Re-encoding changes the container, so `shot.png` would lie about its contents.
  static func fileName(_ name: String, forMimeType mimeType: String) -> String {
    let ext = mimeType == "image/png" ? ".png" : ".jpg"
    let dot = name.jsLastIndex(of: 0x2E, from: name.jsLength)
    let base = dot > 0 ? name.jsSlice(0, dot) : (name.isEmpty ? "image" : name)
    return "\(base)\(ext)"
  }

  // MARK: Decoding

  private static func source(_ data: Data) -> CGImageSource? {
    CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
  }

  public static func pixelSize(of data: Data) -> CGSize? {
    guard let source = source(data), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: width, height: height)
  }

  /// A decode scaled so the longest edge is at most `maxPixel`, honoring EXIF orientation.
  private static func decode(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
    CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  }

  private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
    var options: [CFString: Any] = [:]
    if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }

  /// JPEG has no alpha: flatten onto white like the web canvas does.
  private static func flattened(_ image: CGImage) -> CGImage? {
    guard let context = CGContext(
      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage()
  }

  /// Walks the dimension ladder and the quality ladder until an encoding fits `budgetBytes`.
  private static func reencode(data: Data, budgetBytes: Int) -> Result<(data: Data, size: CGSize), Failure> {
    guard let source = source(data), let size = pixelSize(of: data) else { return .failure(.unreadable) }
    let base = min(maxDimension, Int(max(size.width, size.height)))
    var decodeFailed = false
    for scale in [1.0] + fallbackScaleSteps {
      let target = max(1, Int((Double(base) * scale).rounded()))
      guard let decoded = decode(source, maxPixel: target), let flat = flattened(decoded) else {
        decodeFailed = true
        continue
      }
      decodeFailed = false
      for quality in qualitySteps {
        guard let encoded = encode(flat, type: .jpeg, quality: quality) else { break }
        if encoded.count <= budgetBytes { return .success((encoded, CGSize(width: flat.width, height: flat.height))) }
      }
    }
    return .failure(decodeFailed ? .unreadable : .tooLarge)
  }

  // MARK: Public entry points

  /// Shrinks `data` until it fits `maxBytes`; images already within the limit pass through
  /// byte for byte. `sourceSizeBytes` is the size of the original when `data` is an intermediate
  /// conversion that grew beyond it.
  public static func compressToByteLimit(
    data: Data, name: String, mimeType: String, maxBytes: Int, sourceSizeBytes: Int? = nil
  ) -> Result<Output, Failure> {
    if data.count <= maxBytes { return .success(Output(data: data, mimeType: mimeType, name: name, recompressed: false, pixelSize: pixelSize(of: data))) }
    if (sourceSizeBytes ?? data.count) > maxCompressibleSourceBytes { return .failure(.tooLarge) }
    switch reencode(data: data, budgetBytes: maxBytes) {
    case .failure(let failure): return .failure(failure)
    case .success(let result):
      return .success(Output(data: result.data, mimeType: "image/jpeg", name: fileName(name, forMimeType: "image/jpeg"), recompressed: true, pixelSize: result.size))
    }
  }

  /// HEIC/HEIF photos are converted to provider-compatible JPEG before the size limit applies.
  public static func prepareForAttachment(data: Data, name: String, mimeType: String, maxBytes: Int) -> Result<Output, Failure> {
    guard AttachmentRules.isHeic(name: name, mimeType: mimeType) else {
      return compressToByteLimit(data: data, name: name, mimeType: mimeType, maxBytes: maxBytes)
    }
    if data.count > maxCompressibleSourceBytes { return .failure(.tooLarge) }
    guard let size = pixelSize(of: data), size.width > 0, size.height > 0 else { return .failure(.unreadable) }
    if size.width * size.height > CGFloat(maxHeicDecodePixels) { return .failure(.tooLarge) }
    guard let source = source(data), let decoded = decode(source, maxPixel: Int(max(size.width, size.height))), let flat = flattened(decoded),
      let jpeg = encode(flat, type: .jpeg, quality: qualitySteps[0])
    else { return .failure(.unreadable) }
    let converted = fileName(name, forMimeType: "image/jpeg")
    switch compressToByteLimit(data: jpeg, name: converted, mimeType: "image/jpeg", maxBytes: maxBytes, sourceSizeBytes: data.count) {
    case .failure(let failure): return .failure(failure)
    case .success(var output):
      output.recompressed = true
      return .success(output)
    }
  }

  /// The payload to persist for a stashed image: verbatim when it fits, otherwise re-encoded.
  public static func compressForStash(data: Data, name: String, mimeType: String, budgetChars: Int = maxStashImageDataURLChars) -> Result<Output, Failure> {
    let originalChars = "data:\(mimeType);base64,".utf16.count + (data.count + 2) / 3 * 4
    if originalChars <= budgetChars { return .success(Output(data: data, mimeType: mimeType, name: name, recompressed: false, pixelSize: pixelSize(of: data))) }
    // The budget is in base64 characters: 3 bytes become 4.
    let budgetBytes = max(0, (budgetChars - "data:image/jpeg;base64,".utf16.count) / 4 * 3)
    switch reencode(data: data, budgetBytes: budgetBytes) {
    case .failure(let failure): return .failure(failure)
    case .success(let result):
      return .success(Output(data: result.data, mimeType: "image/jpeg", name: fileName(name, forMimeType: "image/jpeg"), recompressed: true, pixelSize: result.size))
    }
  }

  /// A square PNG thumbnail (center crop) for the attachment shelf.
  public static func thumbnail(of data: Data, side: Int = 256) -> Data? {
    guard let source = source(data), let size = pixelSize(of: data), size.width > 0, size.height > 0 else { return nil }
    // Decode large enough that the shorter edge still covers the thumbnail after the center crop.
    let maxPixel = Int((CGFloat(side) * max(size.width, size.height) / min(size.width, size.height)).rounded(.up))
    guard let image = decode(source, maxPixel: min(maxPixel, Int(max(size.width, size.height)))) else { return nil }
    let edge = min(image.width, image.height)
    guard edge > 0, let cropped = image.cropping(to: CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)) else { return nil }
    let dimension = min(side, edge)
    guard let context = CGContext(
      data: nil, width: dimension, height: dimension, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
    return context.makeImage().flatMap { encode($0, type: .png, quality: nil) }
  }

  public static func dataURL(data: Data, mimeType: String) -> String { "data:\(mimeType);base64,\(data.base64EncodedString())" }

  /// Bytes behind a base64 data URL.
  public static func data(fromDataURL url: String) -> Data? {
    guard let comma = url.firstIndex(of: ",") else { return nil }
    return Data(base64Encoded: String(url[url.index(after: comma)...]))
  }
}
