import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import T3Composer

@Suite("Image compression") struct ImageCompressionTests {
  /// A gradient with noise: compresses poorly, so it exercises the quality and dimension ladders.
  static func image(width: Int, height: Int, type: UTType = .png, alpha: Bool = false) -> Data {
    var generator = SystemRandomNumberGenerator()
    let info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let stride = context.bytesPerRow
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * stride + x * 4
        pixels[offset] = UInt8((x * 255) / max(1, width)) ^ UInt8.random(in: 0...60, using: &generator)
        pixels[offset + 1] = UInt8((y * 255) / max(1, height)) ^ UInt8.random(in: 0...60, using: &generator)
        pixels[offset + 2] = UInt8.random(in: 0...255, using: &generator)
        pixels[offset + 3] = alpha ? 128 : 255
      }
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }

  @Test func imagesWithinTheLimitPassThroughByteForByte() throws {
    let data = Self.image(width: 64, height: 64)
    let result = try ImageCompression.compressToByteLimit(data: data, name: "a.png", mimeType: "image/png", maxBytes: 10_000_000).get()
    #expect(result.data == data && !result.recompressed && result.name == "a.png" && result.mimeType == "image/png")
  }

  @Test func oversizedImagesAreShrunkToFit() throws {
    let data = Self.image(width: 1600, height: 1200)
    let limit = data.count / 4
    let result = try ImageCompression.compressToByteLimit(data: data, name: "shot.png", mimeType: "image/png", maxBytes: limit).get()
    #expect(result.recompressed && result.data.count <= limit)
    #expect(result.mimeType == "image/jpeg" && result.name == "shot.jpg")
    #expect(ImageCompression.pixelSize(of: result.data) != nil)
  }

  @Test func impossibleBudgetsAndUnreadableDataFailDistinctly() {
    let data = Self.image(width: 400, height: 400)
    if case .failure(let failure) = ImageCompression.compressToByteLimit(data: data, name: "a.png", mimeType: "image/png", maxBytes: 10) { #expect(failure == .tooLarge) } else { Issue.record("expected failure") }
    if case .failure(let failure) = ImageCompression.compressToByteLimit(data: Data(repeating: 7, count: 5000), name: "a.png", mimeType: "image/png", maxBytes: 100) { #expect(failure == .unreadable) } else { Issue.record("expected failure") }
    if case .failure(let failure) = ImageCompression.compressToByteLimit(data: Data(count: 1), name: "a.png", mimeType: "image/png", maxBytes: 0, sourceSizeBytes: 60 * 1024 * 1024) { #expect(failure == .tooLarge) } else { Issue.record("expected failure") }
  }

  @Test func heicPhotosBecomeJPEG() throws {
    let heic = Self.image(width: 300, height: 200, type: .heic)
    let result = try ImageCompression.prepareForAttachment(data: heic, name: "IMG_1.HEIC", mimeType: "", maxBytes: 10_000_000).get()
    #expect(result.mimeType == "image/jpeg" && result.name == "IMG_1.jpg" && result.recompressed)
    let source = CGImageSourceCreateWithData(result.data as CFData, nil)!
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    #expect(ImageCompression.pixelSize(of: result.data) == CGSize(width: 300, height: 200))
  }

  @Test func stashBudgetIsMeasuredInBase64Characters() throws {
    let data = Self.image(width: 900, height: 700)
    let budget = 260_000
    let result = try ImageCompression.compressForStash(data: data, name: "a.png", mimeType: "image/png", budgetChars: budget).get()
    #expect(ImageCompression.dataURL(data: result.data, mimeType: result.mimeType).utf16.count <= budget)
    let small = Self.image(width: 8, height: 8)
    let verbatim = try ImageCompression.compressForStash(data: small, name: "s.png", mimeType: "image/png").get()
    #expect(verbatim.data == small && !verbatim.recompressed)
  }

  @Test func thumbnailsAreSquarePNGs() throws {
    let thumbnail = try #require(ImageCompression.thumbnail(of: Self.image(width: 500, height: 200), side: 64))
    #expect(ImageCompression.pixelSize(of: thumbnail) == CGSize(width: 64, height: 64))
  }

  @Test func dataURLRoundTrips() {
    let data = Data((0..<255).map { UInt8($0) })
    #expect(ImageCompression.data(fromDataURL: ImageCompression.dataURL(data: data, mimeType: "image/png")) == data)
  }
}
