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
