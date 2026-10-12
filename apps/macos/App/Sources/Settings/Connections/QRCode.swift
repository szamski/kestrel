import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code of `text`, drawn with hard edges on white so any phone camera reads it in light and dark mode.
struct QRCodeView: View {
  let text: String
  var side: CGFloat = 180

  var body: some View {
    Group {
      if let image = Self.image(for: text) {
        Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
      } else {
        Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .frame(width: side, height: side)
    .background(.white, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityLabel("QR code of the pairing link")
  }

  /// Module size 8 px; `CIQRCodeGenerator` output is one pixel per module.
  static func image(for text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
  }
}
