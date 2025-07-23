import Foundation
import CoreGraphics
import AppKit

/// Returns a fast perceptual similarity between two images using tiny grayscale thumbnails.
/// 1.0 means identical, 0.0 means completely different.
public func tinyThumbnailSimilarity(_ image1: CGImage, _ image2: CGImage, thumbSize: Int = 8) -> Double {
    let size = CGSize(width: thumbSize, height: thumbSize)
    guard
        let ctx1 = createGrayBitmapContext(size: size),
        let ctx2 = createGrayBitmapContext(size: size)
    else { return 0.0 }

    ctx1.draw(image1, in: CGRect(origin: .zero, size: size))
    ctx2.draw(image2, in: CGRect(origin: .zero, size: size))

    guard let d1 = ctx1.data, let d2 = ctx2.data else { return 0.0 }

    let pixelCount = thumbSize * thumbSize
    var matches = 0
    for i in 0..<pixelCount {
        if d1.load(fromByteOffset: i, as: UInt8.self) == d2.load(fromByteOffset: i, as: UInt8.self) {
            matches += 1
        }
    }
    return Double(matches) / Double(pixelCount)
}

/// Returns a grayscale bitmap CGContext for thumbnail comparison.
public func createGrayBitmapContext(size: CGSize) -> CGContext? {
    let width = Int(size.width)
    let height = Int(size.height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    return CGContext(data: nil,
                     width: width,
                     height: height,
                     bitsPerComponent: 8,
                     bytesPerRow: width,
                     space: colorSpace,
                     bitmapInfo: 0)
}
