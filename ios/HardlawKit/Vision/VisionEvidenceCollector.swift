import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

// MARK: - Vision Evidence Models

/// Types of evidence collectable via Vision framework.
public enum VisionEvidenceType: String, Sendable, Codable {
    case text
    case face
    case bodyPose
    case document
    case featurePrint
}

/// A single piece of evidence extracted by Vision.
public struct VisionEvidence: Sendable, Equatable {
    public let type: VisionEvidenceType
    public let value: String
    public let boundingBox: CGRect
    public let confidence: Float

    public init(type: VisionEvidenceType, value: String, boundingBox: CGRect, confidence: Float) {
        self.type = type
        self.value = value
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Structured OCR result.
public struct OCRResult: Sendable, Equatable {
    public let fullText: String
    public let lines: [String]

    public init(fullText: String, lines: [String]) {
        self.fullText = fullText
        self.lines = lines
    }
}

/// Bundle of evidence + source material for Court registration.
public struct EvidenceBundle: Sendable {
    public let evidenceRefs: [EvidenceRef]
    public let sourceMaterial: [String: String]

    public init(evidenceRefs: [EvidenceRef], sourceMaterial: [String: String]) {
        self.evidenceRefs = evidenceRefs
        self.sourceMaterial = sourceMaterial
    }
}

// MARK: - VisionEvidenceCollector

/// Collects evidence from images using Apple's Vision framework.
/// All processing runs on ANE (Apple Neural Engine) where available.
public final class VisionEvidenceCollector: @unchecked Sendable {

    public init() {}

    /// Shared Core Image context for preprocessing. Lazy so the collector
    /// stays cheap to create and reuses the rendering pipeline across calls.
    private lazy var ciContext = CIContext()

    // MARK: - OCR (Text Recognition)

    /// Recognize text in a CGImage (English + Simplified Chinese).
    public func recognizeText(in cgImage: CGImage) async throws -> OCRResult {
        try recognize(cgImage, languages: ["en-US", "zh-Hans"])
    }

    /// Recognize Chinese text in a CGImage, optimized for low-quality scans
    /// and handwritten annotations on legal documents.
    ///
    /// Preprocesses the image (grayscale → contrast stretch → deskew →
    /// binarization) before running Vision OCR with Chinese-first language
    /// settings. Falls back to the unprocessed image if preprocessing loses
    /// the text, so clean digital images still OCR correctly.
    public func recognizeTextChinese(in cgImage: CGImage) async throws -> OCRResult {
        let processed = preprocessForChineseText(cgImage)
        let result = try recognize(processed, languages: ["zh-Hans", "zh-Hant"])

        // If preprocessing destroyed the text (e.g. a clean digital scan whose
        // thin anti-aliased strokes got thresholded away), retry on the
        // original pixels.
        let trimmed = result.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 2 {
            return try recognize(cgImage, languages: ["zh-Hans", "zh-Hant"])
        }
        return result
    }

    /// Shared Vision OCR pipeline. Uses the accurate recognition level with
    /// language correction, the latest text-recognition revision, and a small
    /// minimum text height so dense legal-document text is not skipped.
    private func recognize(_ cgImage: CGImage, languages: [String]) throws -> OCRResult {
        var requestError: Error?
        let request = VNRecognizeTextRequest { _, error in
            requestError = error
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.01
        request.revision = VNRecognizeTextRequestRevision3

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let requestError { throw requestError }

        guard let observations = request.results else {
            return OCRResult(fullText: "", lines: [])
        }

        // Sort top-to-bottom by bounding box
        let sorted = observations.sorted { a, b in
            a.boundingBox.minY > b.boundingBox.minY
        }

        var lines: [String] = []
        for obs in sorted {
            if let topCandidate = obs.topCandidates(1).first {
                lines.append(topCandidate.string)
            }
        }

        return OCRResult(fullText: lines.joined(separator: "\n"), lines: lines)
    }

    // MARK: - Chinese Document Preprocessing

    /// Preprocess a CGImage for Chinese text recognition: grayscale, contrast
    /// stretch, deskew, and binarization. Degrades gracefully — if any stage
    /// fails, the best result so far (or the original image) is returned.
    public func preprocessForChineseText(_ cgImage: CGImage) -> CGImage {
        preprocess(cgImage, contrast: 2.0, threshold: 0.5, binarize: true, deskew: true)
    }

    /// Preprocess with explicit control over contrast, binarization threshold,
    /// and whether deskew/binarization are applied.
    public func preprocessForChineseText(
        _ cgImage: CGImage,
        contrast: Float,
        threshold: Float,
        binarize: Bool,
        deskew: Bool
    ) -> CGImage {
        preprocess(cgImage, contrast: contrast, threshold: threshold, binarize: binarize, deskew: deskew)
    }

    /// Core preprocessing pipeline. Every stage guards its output so a failure
    /// at any point falls back to the best result so far.
    private func preprocess(
        _ cgImage: CGImage,
        contrast: Float,
        threshold: Float,
        binarize: Bool,
        deskew: Bool
    ) -> CGImage {
        var ciImage = CIImage(cgImage: cgImage)

        // 1. Grayscale — removes color noise (stamps, background tint) that
        //    confuses Chinese glyph recognition.
        let mono = CIFilter.photoEffectMono()
        mono.inputImage = ciImage
        guard let gray = mono.outputImage else { return cgImage }
        ciImage = gray

        // 2. Contrast stretch — separates faint strokes from the paper.
        let controls = CIFilter.colorControls()
        controls.inputImage = ciImage
        controls.contrast = contrast
        controls.saturation = 0
        controls.brightness = 0
        guard let contrasted = controls.outputImage else { return cgImage }
        ciImage = contrasted

        // 3. Deskew — straighten a skewed page before thresholding so glyph
        //    structure is preserved.
        if deskew, let corrected = deskewed(ciImage, original: cgImage) {
            ciImage = corrected
        }

        // 4. Binarization — hard black/white threshold for printed scans.
        if binarize {
            let thresholdFilter = CIFilter.colorThreshold()
            thresholdFilter.inputImage = ciImage
            thresholdFilter.threshold = threshold
            guard let binary = thresholdFilter.outputImage else { return cgImage }
            ciImage = binary
        }

        guard let out = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return cgImage }
        return out
    }

    /// Detect the dominant document rectangle and apply perspective correction.
    /// Returns nil when no high-confidence quad is found, leaving the caller
    /// with the un-deskewed image.
    private func deskewed(_ ciImage: CIImage, original: CGImage) -> CIImage? {
        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.minimumConfidence = 0.5
        rectRequest.minimumAspectRatio = 0.3
        rectRequest.maximumAspectRatio = 2.0
        rectRequest.minimumSize = 0.3
        rectRequest.maximumObservations = 1

        let handler = VNImageRequestHandler(cgImage: original, options: [:])
        try? handler.perform([rectRequest])

        guard let rect = rectRequest.results?.first else { return nil }
        // Quad must dominate the frame — anything smaller risks cropping content.
        guard rect.boundingBox.width >= 0.4, rect.boundingBox.height >= 0.25 else { return nil }

        // VNRectangleObservation corners are normalized, origin bottom-left.
        let width = ciImage.extent.width
        let height = ciImage.extent.height
        func toPoints(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: $0.x * width, y: (1 - $0.y) * height) }
        }
        let corners = toPoints([rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft])
        // Reject degenerate quads that leave the image bounds.
        for corner in corners where corner.x < 0 || corner.y < 0 || corner.x > width || corner.y > height {
            return nil
        }

        let perspective = CIFilter.perspectiveCorrection()
        perspective.inputImage = ciImage
        perspective.topLeft = corners[0]
        perspective.topRight = corners[1]
        perspective.bottomRight = corners[2]
        perspective.bottomLeft = corners[3]
        return perspective.outputImage
    }

    // MARK: - Comprehensive Evidence Collection

    /// Collect all available evidence types from an image.
    /// Runs multiple Vision requests in one batch for ANE efficiency.
    public func collectEvidence(from cgImage: CGImage) async throws -> EvidenceBundle {
        // OCR
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = ["en-US", "zh-Hans"]

        // Face detection
        let faceRequest = VNDetectFaceRectanglesRequest()

        // Document/rectangle detection
        let rectRequest = VNDetectRectanglesRequest()
        rectRequest.minimumAspectRatio = 0.3

        // Run all requests through ONE handler — Vision batches them for ANE
        // efficiency instead of re-reading the image three times.
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([textRequest, faceRequest, rectRequest])
        } catch {
            // Batch failed (e.g. an unsupported request on some device) — the
            // text request must not be lost, so retry it alone.
            try handler.perform([textRequest])
        }

        var refs: [EvidenceRef] = []
        var material: [String: String] = [:]

        // Process OCR results
        let textObs = textRequest.results ?? []
        let sortedText = textObs.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        var fullText = ""
        for (i, obs) in sortedText.enumerated() {
            if let topCandidate = obs.topCandidates(1).first {
                let line = topCandidate.string
                fullText += line + "\n"
                let loc = String(format: "x:%.2f,y:%.2f,w:%.2f,h:%.2f",
                    obs.boundingBox.minX, obs.boundingBox.minY,
                    obs.boundingBox.width, obs.boundingBox.height)
                refs.append(EvidenceRef(
                    source: "ocr_frame",
                    location: loc,
                    snippet: line,
                    kind: "text"
                ))
                // Also register each line individually for fine-grained verification
                material[["ocr_line_", String(i)].joined()] = line
            }
        }
        material["ocr_frame"] = fullText.trimmingCharacters(in: .newlines)

        // Process face results
        let faceObs = faceRequest.results ?? []
        if !faceObs.isEmpty {
            var faceSummary = ""
            for face in faceObs {
                let loc = String(format: "x:%.2f,y:%.2f,w:%.2f,h:%.2f",
                    face.boundingBox.minX, face.boundingBox.minY,
                    face.boundingBox.width, face.boundingBox.height)
                let conf = String(format: "%.2f", face.confidence)
                let detail = "face detected (conf \(conf))"
                faceSummary += detail + "\n"
                refs.append(EvidenceRef(
                    source: "vision_analysis",
                    location: loc,
                    snippet: detail,
                    kind: "vision"
                ))
            }
            material["vision_analysis"] = faceSummary.trimmingCharacters(in: .newlines)
        }

        // Process rectangle results
        let rectObs = rectRequest.results ?? []
        if !rectObs.isEmpty {
            var rectSummary = ""
            for (_, rect) in rectObs.enumerated() {
                let loc = String(format: "x:%.2f,y:%.2f,w:%.2f,h:%.2f",
                    rect.boundingBox.minX, rect.boundingBox.minY,
                    rect.boundingBox.width, rect.boundingBox.height)
                let conf = String(format: "%.2f", rect.confidence)
                let detail = "rectangle detected (conf \(conf))"
                rectSummary += detail + "\n"
                refs.append(EvidenceRef(
                    source: "vision_analysis",
                    location: loc,
                    snippet: detail,
                    kind: "vision"
                ))
            }
            if let existingVision = material["vision_analysis"] {
                material["vision_analysis"] = existingVision + "\n" + rectSummary.trimmingCharacters(in: .newlines)
            } else {
                material["vision_analysis"] = rectSummary.trimmingCharacters(in: .newlines)
            }
        }

        return EvidenceBundle(evidenceRefs: refs, sourceMaterial: material)
    }
}
