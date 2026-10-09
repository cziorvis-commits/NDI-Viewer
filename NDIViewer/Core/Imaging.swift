import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Converts BGRX/BGRA NDI frames to JPEG or CVPixelBuffers. Must be used before the frame is freed.
enum FrameImaging {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

    static func isSupported(_ f: NDIlib_video_frame_v2_t) -> Bool {
        (f.FourCC == NDIlib_FourCC_video_type_BGRX || f.FourCC == NDIlib_FourCC_video_type_BGRA)
            && f.p_data != nil && f.xres > 0 && f.yres > 0
    }

    static func jpeg(from f: NDIlib_video_frame_v2_t, maxWidth: Int, quality: Double) -> Data? {
        guard isSupported(f), let base = f.p_data else { return nil }
        let w = Int(f.xres), h = Int(f.yres), stride = Int(f.line_stride_in_bytes)
        guard let provider = CGDataProvider(dataInfo: nil, data: base, size: stride * h,
                                            releaseData: { _, _, _ in }) else { return nil }
        guard let full = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: stride, space: colorSpace,
                                 bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        var image = full
        if w > maxWidth {
            let tw = maxWidth & ~1
            let th = max(2, Int((Double(h) * Double(tw) / Double(w)).rounded()) & ~1)
            guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
            guard let scaled = ctx.makeImage() else { return nil }
            image = scaled
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Copies frames into IOSurface-backed pixel buffers for native playback.
final class PixelBufferMaker {
    private var pool: CVPixelBufferPool?
    private var width = 0, height = 0

    func make(from f: NDIlib_video_frame_v2_t) -> CVPixelBuffer? {
        guard FrameImaging.isSupported(f), let src = f.p_data else { return nil }
        let w = Int(f.xres), h = Int(f.yres), srcStride = Int(f.line_stride_in_bytes)
        if pool == nil || w != width || h != height {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            width = w; height = h
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pb)
        let rowBytes = min(srcStride, dstStride, w * 4)
        if srcStride == dstStride {
            memcpy(dst, src, srcStride * h)
        } else {
            for y in 0..<h {
                memcpy(dst + y * dstStride, src + y * srcStride, rowBytes)
            }
        }
        return pb
    }
}
