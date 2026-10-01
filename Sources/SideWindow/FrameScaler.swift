import CoreImage
import CoreVideo
import IOSurface

/// 拡大表示のときに、取り込んだ映像を高品質に引き伸ばす（Lanczos 補間 + 輪郭の強調、GPU で処理）。
/// 画面に単純に引き伸ばさせるとぼやけるので、パネルの画素数に合わせてこちらで拡大してから渡す
final class FrameScaler {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    /// 表示中のバッファがすぐ使い回されないよう、直近のものを持っておく
    private var recent: [CVPixelBuffer] = []

    /// source の crop の範囲（割合・左上原点）を size（ピクセル）に拡大する。拡大が不要なら nil
    func upscale(_ source: CVPixelBuffer, crop: CGRect, to size: CGSize, sharpen: Bool) -> IOSurface? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(source))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        // Core Image は左下原点
        let region = CGRect(x: crop.minX * sourceWidth, y: (1 - crop.maxY) * sourceHeight,
                            width: crop.width * sourceWidth, height: crop.height * sourceHeight)
        guard width > 0, height > 0, region.width >= 1, region.height >= 1,
              CGFloat(width) > region.width * 1.05 else { return nil }

        guard let output = makeBuffer(width: width, height: height) else { return nil }
        let scaleX = CGFloat(width) / region.width
        let scaleY = CGFloat(height) / region.height
        var result = CIImage(cvPixelBuffer: source, options: [.colorSpace: colorSpace])
            // 補間で参照する周りの数ピクセルも含めて切り出す（範囲外は端の色で埋める）
            .clampedToExtent()
            .cropped(to: region.insetBy(dx: -4, dy: -4))
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])
        if sharpen {
            // 拡大率が大きいほど輪郭がぼけるので、半径を合わせて強める
            result = result.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.5,
                kCIInputRadiusKey: min(3, 0.8 * scaleY),
            ])
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(result.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)

        recent.append(output)
        if recent.count > 3 { recent.removeFirst() }
        guard let surface = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue() else { return nil }
        return unsafeBitCast(surface, to: IOSurface.self)
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
            recent.removeAll()
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        }
        return buffer
    }
}
