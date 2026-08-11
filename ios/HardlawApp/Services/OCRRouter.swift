import Foundation
import CoreGraphics
import HardlawKit

/// OCR Router — device uses PaddleOCR, simulator uses Vision, failure falls back.
public enum OCRRouter {
    public static func recognize(_ cgImage: CGImage) async -> [String] {
        #if targetEnvironment(simulator)
        return await visionOCR(cgImage)
        #else
        // Device: try PaddleOCR first, fall back to Vision
        if let engine = paddleEngine() {
            var error: NSError?
            let result = engine.recognize(cgImage, error: &error)
            if error == nil, !result.isEmpty { return result }
        }
        return await visionOCR(cgImage)
        #endif
    }

    private static func paddleEngine() -> PaddleOCREngine? {
        let models = Bundle.main.resourceURL?.appendingPathComponent("../../HardlawApp/PaddleOCR/models")
            ?? Bundle.main.bundleURL.appendingPathComponent("HardlawApp/PaddleOCR/models")
        return PaddleOCREngine(
            detModel: models.appendingPathComponent("inference.pdmodel").path,
            recModel: models.appendingPathComponent("inference.pdiparams").path,
            dictPath: models.appendingPathComponent("ppocr_keys.txt").path
        )
    }

    private static func visionOCR(_ cgImage: CGImage) async -> [String] {
        let collector = VisionEvidenceCollector()
        if let result = try? await collector.recognizeText(in: cgImage) {
            return result.lines
        }
        return []
    }
}
