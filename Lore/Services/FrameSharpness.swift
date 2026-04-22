import CoreImage
import UIKit

/// Rough sharpness proxy for a single frame. Used to rank the last few
/// video frames and pick the crispest one to feed into the vision model
/// while a higher-resolution `capturePhoto()` is still in flight.
///
/// Technique: downsample to 128x128 grayscale, apply a 3x3 Laplacian
/// convolution, then compute the variance of the edge response. Blurred
/// images smooth everything toward midgray (low variance); sharp images
/// produce strong positive and negative edge responses (high variance).
///
/// The absolute numbers are arbitrary — only useful for comparing frames
/// captured in the same session. Don't persist or compare across cameras.
enum FrameSharpness {
  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private static let sampleSize: CGFloat = 128

  static func score(_ image: UIImage) -> Double {
    guard let cg = image.cgImage else { return 0 }
    let ci = CIImage(cgImage: cg)

    let width = CGFloat(cg.width)
    let height = CGFloat(cg.height)
    guard width > 0, height > 0 else { return 0 }
    let scale = min(sampleSize / width, sampleSize / height)
    let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    // Convert to grayscale. CIPhotoEffectMono gives a luma-weighted gray
    // with R=G=B in sRGB, which is what we want for edge analysis.
    let gray = scaled.applyingFilter("CIPhotoEffectMono")

    // 3x3 Laplacian. Bias 0.5 keeps negative responses from clipping to
    // zero in the 8-bit readback — otherwise half the edge energy is lost.
    let kernel = CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9)
    let laplacian = gray.applyingFilter(
      "CIConvolution3X3",
      parameters: [
        "inputWeights": kernel,
        "inputBias": 0.5,
      ]
    )

    let extent = laplacian.extent
    guard extent.width > 0, extent.height > 0 else { return 0 }

    // Variance via E[X^2] - E[X]^2. Squaring = multiply the image by
    // itself; CIMultiplyCompositing does pixelwise multiply.
    let meanImage = laplacian.applyingFilter(
      "CIAreaAverage",
      parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]
    )
    let squared = laplacian.applyingFilter(
      "CIMultiplyCompositing",
      parameters: [kCIInputBackgroundImageKey: laplacian]
    )
    let meanSquaredImage = squared.applyingFilter(
      "CIAreaAverage",
      parameters: [kCIInputExtentKey: CIVector(cgRect: extent)]
    )

    let mean = readOnePixel(meanImage) ?? 0
    let meanSquared = readOnePixel(meanSquaredImage) ?? 0
    // Shifting the image by 0.5 doesn't change its variance, so this
    // yields the variance of the raw Laplacian response.
    return max(0, meanSquared - mean * mean)
  }

  private static func readOnePixel(_ image: CIImage) -> Double? {
    var pixel = [UInt8](repeating: 0, count: 4)
    ciContext.render(
      image,
      toBitmap: &pixel,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    // Grayscale, so R carries the value. Normalize to [0, 1].
    return Double(pixel[0]) / 255.0
  }
}
