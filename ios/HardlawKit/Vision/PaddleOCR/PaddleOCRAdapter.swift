import Foundation
import CoreGraphics

/// Swift wrapper for PaddleOCR Lite on-device inference.
///
/// Architecture:
///   Paddle Lite C++ static library (libpaddle_api_light_bundled.a, 49MB)
///   → Objective-C++ wrapper (PaddleOCRWrapper.mm)
///   → Swift adapter (this file)
///
/// Model files (.nb format) must be bundled separately:
///   - PP-OCRv6_medium_det.nb  (text detection, ~62MB → ~8MB optimized)
///   - PP-OCRv6_medium_rec.nb  (text recognition, ~76MB → ~10MB optimized)
///
/// Status: Library linked. Model conversion + inference pipeline pending.
public final class PaddleOCRAdapter {

    /// Whether the Paddle Lite library is available (always true once linked).
    public static var isAvailable: Bool {
        // When models are loaded, check actual availability
        return true
    }

    /// Placeholder — full OCR pipeline is pending model conversion to .nb format.
    /// For now, OCR is handled by VisionEvidenceCollector + enhanced preprocessing.
    public func recognize(_ cgImage: CGImage) async throws -> String {
        // TODO: Model conversion + inference pipeline
        // Steps remaining:
        // 1. Convert PaddleX models → Paddle inference → Paddle Lite .nb
        // 2. Load .nb models from bundle
        // 3. Create Paddle Lite predictor
        // 4. Preprocess image (resize, normalize)
        // 5. Run detection → crop text regions
        // 6. Run recognition → output Chinese text
        throw PaddleOCRError.modelsNotConverted
    }
}

public enum PaddleOCRError: Error {
    case modelsNotConverted
    case libraryNotAvailable
    case inferenceFailed(String)
}
