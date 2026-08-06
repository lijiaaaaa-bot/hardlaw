import Foundation
import CoreGraphics

// MARK: - OCR Backend Protocol

public protocol OCRBackend: Sendable {
    static var displayName: String { get }
    static var isAvailable: Bool { get }
    func recognize(_ cgImage: CGImage) async throws -> [String]
}

// MARK: - PaddleOCR Backend (device only)

public final class PaddleOCRBackend: OCRBackend, @unchecked Sendable {
    public static let displayName = "PaddleOCR"
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    private let engine: PaddleOCREngine

    public init?(modelsDir: URL) {
        let detModel = modelsDir.appendingPathComponent("ch_PP-OCRv4_det.pdmodel").path
        let detParams = modelsDir.appendingPathComponent("ch_PP-OCRv4_det.pdiparams").path
        let recModel = modelsDir.appendingPathComponent("ch_PP-OCRv4_rec.pdmodel").path
        let recParams = modelsDir.appendingPathComponent("ch_PP-OCRv4_rec.pdiparams").path
        let dictPath = modelsDir.appendingPathComponent("ppocr_keys.txt").path

        guard let eng = PaddleOCREngine(
            detModel: detModel, detParams: detParams,
            recModel: recModel, recParams: recParams,
            dictPath: dictPath
        ) else { return nil }
        self.engine = eng
    }

    public func recognize(_ cgImage: CGImage) async throws -> [String] {
        var error: NSError?
        let result = engine.recognize(cgImage, error: &error)
        if let error { throw error }
        return result
    }
}
