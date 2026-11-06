import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Scales an image to fit a box, keeping its proportions and never enlarging it.
public enum ImageFit {
    /// The largest size with `source`'s aspect ratio that fits in `box` and is no bigger than `source`.
    public static func size(of source: CGSize, in box: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(1, box.width / source.width, box.height / source.height)
        return CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
    }
}

/// An image re-encoded for the site: its pixel size, encoded bytes and file extension.
public struct ProcessedImage: Equatable, Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    /// `jpg`, or `png` when the image has transparency.
    public var fileExtension: String
}

public enum ImageError: Error, Equatable, LocalizedError {
    case notAnImage
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .notAnImage: "That is not an image Breezy can read."
        case .encodingFailed: "The image could not be converted."
        }
    }
}

/// Fits images to the boxes the site draws them in, as new JPEG (or PNG, for transparency) files with no metadata
/// (the site repository is public, so no location or camera data goes with a picture).
public enum ImageResizer {
    /// The node page banner: the content column at 2× (46rem wide) by its 14rem height cap.
    public static let headerBox = CGSize(width: 1472, height: 448)
    /// The bookshelf thumbnail: a 9rem shelf slot at 2×, up to 16rem wide.
    public static let teaserBox = CGSize(width: 512, height: 320)

    public static func resize(_ data: Data, fitting box: CGSize, quality: Double = 0.85) throws -> ProcessedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw ImageError.notAnImage }
        // Orientations 5...8 are turned a quarter: the picture is taller than the stored pixels say.
        let turned = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let shown = CGSize(width: turned ? h : w, height: turned ? w : h)
        let target = ImageFit.size(of: shown, in: box)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageError.notAnImage }
        let width = scaled.width, height = scaled.height

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let transparent = hasTransparency(scaled, space: space)
        let info = transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: info.rawValue) else { throw ImageError.encodingFailed }
        context.draw(scaled, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flat = context.makeImage() else { throw ImageError.encodingFailed }

        let type = transparent ? UTType.png : .jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw ImageError.encodingFailed }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodingFailed }
        return ProcessedImage(data: out as Data, width: width, height: height, fileExtension: transparent ? "png" : "jpg")
    }

    /// Whether any pixel is not fully opaque. (A screenshot has an alpha channel but is opaque: it becomes a JPEG.)
    private static func hasTransparency(_ image: CGImage, space: CGColorSpace) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true } // unknown: keep the alpha channel
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }
}

/// The banner and thumbnail files made for a node from one picture.
public enum HeaderImages {
    /// `/assets/images/<slug>-header.jpg` and `-teaser`: named after the node, so replacing a picture replaces the file.
    public static func sitePath(slug: String, teaser: Bool, fileExtension: String) -> String {
        "/assets/images/\(slug)-\(teaser ? "teaser" : "header").\(fileExtension)"
    }
}
