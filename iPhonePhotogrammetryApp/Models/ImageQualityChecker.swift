import CoreImage
import Accelerate

// MARK: - Photo Quality Checker

enum ExposureState: String {
    case underexposed = "Too dark"
    case ok = "OK"
    case overexposed = "Too bright"
}

struct QualityResult {
    let isAcceptable: Bool
    let isBlurry: Bool
    let exposureState: ExposureState
    let blurScore: Float      // higher = sharper
    let brightness: Float     // 0.0–1.0 average
    
    var issues: [String] {
        var list: [String] = []
        if isBlurry { list.append("Blurry (score: \(String(format: "%.0f", blurScore)))") }
        if exposureState != .ok { list.append(exposureState.rawValue) }
        return list
    }
}

struct ImageQualityChecker {
    
    // MARK: - Thresholds
    
    /// Laplacian variance below this = blurry (lowered for room coverage)
    private static let blurThreshold: Float = 15.0
    /// Average brightness below this = underexposed (lowered for dim rooms)
    private static let darkThreshold: Float = 0.03
    /// Average brightness above this = overexposed (raised to allow bright windows)
    private static let brightThreshold: Float = 0.97
    
    // MARK: - Public API

    /// Run all quality checks on a CIImage. Returns combined result.
    static func check(_ image: CIImage) -> QualityResult {
        let blurScore = computeBlurScore(image)
        let brightness = computeBrightness(image)
        
        let isBlurry = blurScore < blurThreshold
        let exposureState: ExposureState
        if brightness < darkThreshold {
            exposureState = .underexposed
        } else if brightness > brightThreshold {
            exposureState = .overexposed
        } else {
            exposureState = .ok
        }
        
        let isAcceptable = !isBlurry && exposureState == .ok
        
        return QualityResult(
            isAcceptable: isAcceptable,
            isBlurry: isBlurry,
            exposureState: exposureState,
            blurScore: blurScore,
            brightness: brightness
        )
    }
    
    // MARK: - Blur Detection (Laplacian Variance)
    
    /// Computes sharpness via Laplacian filter variance.
    /// Higher value = sharper image.
    private static func computeBlurScore(_ image: CIImage) -> Float {
        let context = CIContext()
        
        // Downscale for performance — 256px wide is enough for blur detection
        let scale = min(1.0, 256.0 / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        // Convert to grayscale
        guard let grayscale = CIFilter(name: "CIPhotoEffectMono", parameters: [kCIInputImageKey: scaled])?.outputImage else {
            return 999  // can't check, assume OK
        }
        
        // Render to pixel buffer
        let extent = grayscale.extent
        let w = Int(extent.width)
        let h = Int(extent.height)
        
        guard w > 0, h > 0 else { return 999 }
        
        var pixelData = [UInt8](repeating: 0, count: w * h)
        context.render(
            grayscale,
            toBitmap: &pixelData,
            rowBytes: w,
            bounds: extent,
            format: .L8,
            colorSpace: CGColorSpaceCreateDeviceGray()
        )
        
        // Laplacian kernel convolution: compute variance of edge response
        var sum: Float = 0
        var sumSq: Float = 0
        var count: Float = 0
        
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let center = Float(pixelData[y * w + x])
                let top    = Float(pixelData[(y-1) * w + x])
                let bottom = Float(pixelData[(y+1) * w + x])
                let left   = Float(pixelData[y * w + (x-1)])
                let right  = Float(pixelData[y * w + (x+1)])
                
                // Laplacian = sum of neighbors - 4*center
                let lap = top + bottom + left + right - 4 * center
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }
        
        guard count > 0 else { return 999 }
        let mean = sum / count
        let variance = (sumSq / count) - (mean * mean)
        return variance
    }
    
    // MARK: - Exposure Check
    
    /// Computes average brightness (0.0–1.0) from the image.
    private static func computeBrightness(_ image: CIImage) -> Float {
        let context = CIContext()
        
        // Use CIAreaAverage to get mean color
        guard let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ]),
        let outputImage = avgFilter.outputImage else {
            return 0.5  // default to acceptable
        }
        
        // Render the 1x1 pixel result
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        
        // Luminance from RGB
        let r = Float(pixel[0]) / 255.0
        let g = Float(pixel[1]) / 255.0
        let b = Float(pixel[2]) / 255.0
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
