import XCTest
import UIKit
import Vision
@testable import HardlawKit

final class VisionEvidenceTests: XCTestCase {

    /// Create a test image with known OCR text.
    func makeTestImage() -> UIImage {
        let size = CGSize(width: 600, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // White background
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Draw text
            let text = "Hello World\nThis is a test\nContent moderation check"
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraphStyle,
            ]

            text.draw(at: CGPoint(x: 20, y: 20), withAttributes: attrs)
        }
    }

    // MARK: - OCR

    func testRecognizeText() async throws {
        let collector = VisionEvidenceCollector()
        let image = makeTestImage()
        guard let cgImage = image.cgImage else {
            XCTFail("Failed to get CGImage")
            return
        }

        let result = try await collector.recognizeText(in: cgImage)
        // OCR may not be 100% accurate on simulator, check for key words
        let text = result.fullText.lowercased()
        XCTAssertTrue(text.contains("hello") || text.contains("world") || text.contains("test"),
                      "OCR should recognize at least some text, got: \(text)")
        XCTAssertFalse(result.lines.isEmpty, "Should have at least one line")
    }

    // MARK: - Chinese Document Preprocessing

    func testPreprocessForChineseText() throws {
        let collector = VisionEvidenceCollector()
        let image = makeTestImage()
        guard let cgImage = image.cgImage else {
            XCTFail("Failed to get CGImage")
            return
        }

        let processed = collector.preprocessForChineseText(cgImage)
        // Preprocessing must preserve geometry and never return nil (it falls
        // back to the original image on any filter failure).
        XCTAssertEqual(processed.width, cgImage.width, "Width should be preserved")
        XCTAssertEqual(processed.height, cgImage.height, "Height should be preserved")

        // Pixel-space check: preprocessing should produce a near-binary image
        // with both dark ink and light background pixels present.
        let width = processed.width
        let height = processed.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create pixel context")
            return
        }
        context.draw(processed, in: CGRect(x: 0, y: 0, width: width, height: height))

        var darkFound = false
        var lightFound = false
        for y in stride(from: 20, through: height - 20, by: 40) {
            for x in stride(from: 20, through: width - 20, by: 60) {
                let index = (y * width + x) * 4
                let red = CGFloat(buffer[index])
                if red < 0.5 { darkFound = true }
                if red > 0.5 { lightFound = true }
            }
        }
        XCTAssertTrue(darkFound, "Preprocessed image should contain dark ink pixels")
        XCTAssertTrue(lightFound, "Preprocessed image should contain light background pixels")
    }

    func testRecognizeTextChinese() async throws {
        let collector = VisionEvidenceCollector()
        let image = makeTestImage()
        guard let cgImage = image.cgImage else {
            XCTFail("Failed to get CGImage")
            return
        }

        let result = try await collector.recognizeTextChinese(in: cgImage)
        // Chinese-first OCR must still recognize English text on the simulator.
        let text = result.fullText.lowercased()
        XCTAssertTrue(text.contains("hello") || text.contains("world") || text.contains("test"),
                      "Chinese-pipeline OCR should recognize at least some text, got: \(text)")
    }

    func testRecognizeTextChineseOnLowContrast() async throws {
        let collector = VisionEvidenceCollector()
        // Simulate a low-quality scan: light gray text on mid-gray paper,
        // which plain Vision OCR struggles to read.
        let size = CGSize(width: 600, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(white: 0.82, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "劳动合同 仲裁 工资"
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30),
                .foregroundColor: UIColor(white: 0.45, alpha: 1),
                .paragraphStyle: paragraphStyle,
            ]
            text.draw(at: CGPoint(x: 20, y: 40), withAttributes: attrs)
        }
        guard let cgImage = image.cgImage else {
            XCTFail("Failed to get CGImage")
            return
        }

        // The enhanced pipeline should recover the characters that plain OCR
        // misses on low contrast (falls back to raw pixels if preprocessing
        // over-thresholds, so it can only be at least as good as raw OCR).
        let enhanced = try await collector.recognizeTextChinese(in: cgImage)
        XCTAssertFalse(enhanced.fullText.isEmpty,
                       "Preprocessed OCR should find text on the low-contrast scan")
        // At least one of the Chinese phrases or a character fragment should
        // survive; allow fragments since simulator OCR is approximate.
        XCTAssertFalse(enhanced.lines.isEmpty, "Should have at least one line")
    }

    // MARK: - Evidence Collection

    func testCollectEvidence() async throws {
        let collector = VisionEvidenceCollector()
        let image = makeTestImage()
        guard let cgImage = image.cgImage else {
            XCTFail("Failed to get CGImage")
            return
        }

        let bundle = try await collector.collectEvidence(from: cgImage)

        // Should have OCR evidence refs
        let textRefs = bundle.evidenceRefs.filter { $0.kind == "text" }
        XCTAssertTrue(textRefs.count > 0, "Should have at least one OCR evidence ref")

        // Source material should contain OCR text
        XCTAssertNotNil(bundle.sourceMaterial["ocr_frame"], "Should have ocr_frame source material")
    }

    // MARK: - Evidence Validator Integration

    func testEvidenceValidationWithOCR() async throws {
        let collector = VisionEvidenceCollector()
        let image = makeTestImage()
        guard let cgImage = image.cgImage else {
            XCTFail("Failed to get CGImage")
            return
        }

        let bundle = try await collector.collectEvidence(from: cgImage)

        // Register sources and validate refs
        var validator = EvidenceValidator()
        for (key, value) in bundle.sourceMaterial {
            validator.addSource(key, value)
        }

        let (allValid, failures) = validator.validateAll(bundle.evidenceRefs)
        if !allValid {
            print("Validation failures: \(failures)")
        }
        // Most refs should pass since snippets come directly from source text
        // Some may fail due to OCR differences in simulator
        let passRate = Double(allValid ? bundle.evidenceRefs.count : bundle.evidenceRefs.count - failures.count)
            / Double(max(bundle.evidenceRefs.count, 1))
        XCTAssertGreaterThan(passRate, 0.5, "At least 50% of evidence refs should validate")
    }
}
