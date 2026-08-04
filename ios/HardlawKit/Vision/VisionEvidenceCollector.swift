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

    // MARK: - OCR (Text Recognition)

    /// Recognize text in a CGImage.
    public func recognizeText(in cgImage: CGImage) async throws -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results as? [VNRecognizedTextObservation] else {
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

        // Perform each request with a fresh handler for broad compatibility
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest])
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest]) // optional
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([rectRequest]) // optional

        var refs: [EvidenceRef] = []
        var material: [String: String] = [:]

        // Process OCR results
        let textObs = (textRequest.results as? [VNRecognizedTextObservation]) ?? []
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
        let faceObs = (faceRequest.results as? [VNFaceObservation]) ?? []
        if !faceObs.isEmpty {
            var faceSummary = ""
            for (i, face) in faceObs.enumerated() {
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
        let rectObs = (rectRequest.results as? [VNRectangleObservation]) ?? []
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
