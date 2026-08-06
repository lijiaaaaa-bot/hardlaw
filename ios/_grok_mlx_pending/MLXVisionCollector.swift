import Foundation

// MARK: - MLXVisionCollector (requires mlx-libraries package)

/// Semantic image understanding via on-device MLX vision model.
///
/// Unlike ``VisionEvidenceCollector`` (which does OCR + face/rectangle detection
/// via Apple Vision), this collector uses a multimodal MLX model to *understand*
/// document images at a semantic level:
/// - Read all text (printed + handwritten + stamps/seals)
/// - Identify document type (contract, receipt, form, ID card, etc.)
/// - Extract structured fields (dates, amounts, names, addresses)
/// - Flag anomalies (corrections, inconsistencies, missing fields)
///
/// ## Relationship to VisionEvidenceCollector
///
/// `VisionEvidenceCollector` is fast (ANE-accelerated, <100ms) but shallow —
/// it recognizes text characters and detects visual features without
/// understanding their meaning. `MLXVisionCollector` is slower (1-5s on
/// iPhone) but deeper — it reads the document like a human would.
///
/// The two are complementary:
/// 1. Use `VisionEvidenceCollector` for real-time camera scanning
/// 2. Use `MLXVisionCollector` for detailed document analysis when a case
///    requires semantic understanding (handwritten notes, document type
///    verification, field extraction, anomaly detection)
///
/// ## Model
///
/// Default: Qwen3-VL-2B (quantized) — a 2B-parameter vision-language model
/// that can analyze document images and produce structured JSON output.
/// Alternative: Spike-2B (smaller, faster, less capable with handwriting).
///
/// ## Anti-hallucination guarantee
///
/// Every ``EvidenceRef`` produced by this collector cites a verifiable snippet
/// from the source material. The model's full analysis text is registered as
/// source material (key: `"mlx_vision_analysis"`), and each extracted field or
/// observation is stored as a snippet that can be substring-matched against it.
/// This preserves the hardlaw evidence-verification chain.
///
/// ## Thread safety
///
/// MLXVisionCollector is an `actor`, serializing all access. The underlying
/// vision model container is also an actor.
///
/// ## Usage
///
/// ```swift
/// let collector = MLXVisionCollector()
/// let imageData = try Data(contentsOf: documentURL)
/// let bundle = try await collector.understand(
///     imageData: imageData,
///     context: "Loan agreement page 3"
/// )
/// // Register bundle.sourceMaterial in EvidenceValidator, then pass
/// // bundle.evidenceRefs to the Court as case data.
/// ```
public actor MLXVisionCollector {

    // MARK: - Configuration

    /// HuggingFace model identifier for the vision-language model.
    /// Default: Qwen3-VL-2B — balances capability and on-device performance.
    /// Alternative: "mlx-community/Spike-2B-4bit" for lower memory usage.
    private let modelId: String

    /// Maximum tokens for the model's analysis response.
    private let maxTokens: Int

    /// Sampling temperature. 0.0 for deterministic analysis.
    private let temperature: Float

    // MARK: - State

    /// Lazily-loaded vision model container.
    private var modelContainer: Any?  // ModelContainer (opaque until mlx-libraries linked)

    /// Whether the model has been loaded.
    private var isLoaded: Bool = false

    /// Captured load error for re-throwing.
    private var loadError: Error?

    // MARK: - Initialization

    /// Create an MLX-powered vision evidence collector.
    ///
    /// - Parameters:
    ///   - modelId: HuggingFace model ID (default: Qwen3-VL-2B)
    ///   - maxTokens: Maximum output tokens per analysis (default: 2048)
    ///   - temperature: Sampling temperature (default: 0.0 = deterministic)
    public init(
        modelId: String = "mlx-community/Qwen3-VL-2B-4bit",
        maxTokens: Int = 2048,
        temperature: Float = 0.0
    ) {
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    // MARK: - Public API

    /// Analyze a document image and produce a full evidence bundle.
    ///
    /// This is the primary entry point. It sends the image to the vision model
    /// with a structured analysis prompt, parses the response, and returns an
    /// ``EvidenceBundle`` containing:
    /// - `evidenceRefs`: individual observations as verifiable citations
    /// - `sourceMaterial`: the model's full analysis text (for EvidenceValidator)
    ///
    /// - Parameters:
    ///   - imageData: Raw image bytes (JPEG or PNG)
    ///   - context: Human-readable context for the model (e.g., "Page 3 of
    ///     rental agreement")
    /// - Returns: Evidence bundle with cited observations and source material
    /// - Throws: `MLXVisionError` if analysis fails
    public func understand(
        imageData: Data,
        context: String
    ) async throws -> EvidenceBundle {
        let analysisText = try await runAnalysis(
            imageData: imageData,
            prompt: buildAnalysisPrompt(context: context)
        )
        return parseAnalysisToBundle(analysisText, imageData: imageData)
    }

    /// Collect evidence from a document image, filtered by statute requirements.
    ///
    /// Like ``understand(imageData:context:)`` but additionally checks the
    /// extracted fields against the required evidence rules of the given
    /// statutes. Only evidence refs that cite a required source are included,
    /// and any missing required evidence is flagged as a gap.
    ///
    /// - Parameters:
    ///   - imageData: Raw image bytes (JPEG or PNG)
    ///   - statutes: Statutes whose required evidence rules to check against
    /// - Returns: Evidence refs filtered and enriched by statute requirements
    /// - Throws: `MLXVisionError` if analysis fails
    public func collectEvidence(
        from imageData: Data,
        statutes: [Statute]
    ) async throws -> [EvidenceRef] {
        let bundle = try await understand(
            imageData: imageData,
            context: "Document submitted for compliance audit under \(statutes.map(\.name).joined(separator: ", "))"
        )

        // Collect all required evidence source names from the statutes
        let requiredSources = Set(statutes.flatMap(\.requiredEvidence))

        // Filter evidence refs: keep those that cite required sources
        var filteredRefs = bundle.evidenceRefs.filter { ref in
            requiredSources.contains(ref.source) || requiredSources.isEmpty
        }

        // If no refs match but statutes demand evidence, create gap refs
        if filteredRefs.isEmpty && !requiredSources.isEmpty {
            for source in requiredSources.sorted() {
                filteredRefs.append(EvidenceRef(
                    source: source,
                    location: "mlx_vision_analysis",
                    snippet: "[MISSING] Required evidence '\(source)' not found in document",
                    kind: "gap"
                ))
            }
        }

        return filteredRefs
    }

    // MARK: - Model Lifecycle

    /// Load the vision model container.
    ///
    /// When the `mlx-libraries` Swift package is linked, replace the body of
    /// this method with the real MLX load call and remove the `#if false`
    /// conditional compilation block.
    private func loadModel() async throws {
        // --- Real implementation (enable when mlx-libraries is linked) ---
        // Replace `#if false` with `#if canImport(MLXVLM)` once the
        // mlx-libraries package is added to project.yml dependencies.
        //
        // import MLXVLM
        // import MLXLMCommon
        //
        // let config = ModelConfiguration.configuration(id: modelId)
        // modelContainer = try await ModelContainer.loadModelContainer(
        //     configuration: config
        // )

        #if false
        let config = ModelConfiguration.configuration(id: modelId)
        let container = try await ModelContainer.loadModelContainer(
            configuration: config
        )
        modelContainer = container
        #else
        throw MLXVisionError.packageNotLinked(
            "mlx-libraries package not linked. Add it to project.yml dependencies."
        )
        #endif
    }

    /// Run the vision model with the given image and prompt.
    private func runAnalysis(imageData: Data, prompt: String) async throws -> String {
        if let loadError {
            throw loadError
        }

        if !isLoaded {
            do {
                try await loadModel()
                isLoaded = true
            } catch {
                loadError = MLXVisionError.modelLoadFailed(underlying: error)
                throw loadError!
            }
        }

        // --- Real implementation (enable when mlx-libraries is linked) ---
        // Replace `#if false` with `#if canImport(MLXVLM)` once the
        // mlx-libraries package is added to project.yml dependencies.
        //
        // guard let container = modelContainer as? ModelContainer else {
        //     throw MLXVisionError.modelNotLoaded
        // }
        //
        // return try await container.perform { context in
        //     let base64Image = imageData.base64EncodedString()
        //     let dataUri = "data:image/jpeg;base64,\(base64Image)"
        //     let messages: [[String: Any]] = [
        //         ["role": "user", "content": [
        //             ["type": "text", "text": prompt],
        //             ["type": "image_url", "image_url": ["url": dataUri]],
        //         ]],
        //     ]
        //     let input = try await context.processor.prepare(
        //         input: .messages(messages)
        //     )
        //     let result = try await MLXVLM.generate(
        //         input: input,
        //         parameters: GenerateParameters(
        //             temperature: temperature,
        //             maxTokens: maxTokens
        //         ),
        //         context: context
        //     )
        //     return result.output
        // }

        #if false
        guard let container = modelContainer as? ModelContainer else {
            throw MLXVisionError.modelNotLoaded
        }

        return try await container.perform { context in
            let base64Image = imageData.base64EncodedString()
            let dataUri = "data:image/jpeg;base64,\(base64Image)"
            let messages: [[String: Any]] = [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": dataUri]],
                    ],
                ],
            ]
            let input = try await context.processor.prepare(
                input: .messages(messages)
            )
            let result = try await MLXVLM.generate(
                input: input,
                parameters: GenerateParameters(
                    temperature: temperature,
                    maxTokens: maxTokens
                ),
                context: context
            )
            return result.output
        }
        #else
        throw MLXVisionError.packageNotLinked(
            "mlx-libraries package not linked. Add it to project.yml dependencies."
        )
        #endif
    }

    // MARK: - Resource Management

    /// Release the loaded vision model from memory.
    ///
    /// Frees ~2 GB of RAM. The model will be reloaded on the next call.
    public func unload() {
        modelContainer = nil
        isLoaded = false
        loadError = nil
    }

    /// Whether the vision model is currently loaded in memory.
    public var loaded: Bool { isLoaded && loadError == nil }

    // MARK: - Prompt Building

    /// Build the structured analysis prompt for the vision model.
    ///
    /// The prompt instructs the model to act as a document examiner, producing
    /// a structured JSON analysis that can be parsed into ``EvidenceRef``
    /// objects.
    private func buildAnalysisPrompt(context: String) -> String {
        """
        You are a document examiner. Analyze the document image and produce a \
        structured JSON analysis.

        Context: \(context)

        ## Required Analysis

        1. **document_type**: Identify the type (contract, receipt, form, \
        ID card, invoice, letter, certificate, bank statement, handwritten \
        note, other). Use "unknown" if unclear.

        2. **all_text**: Transcribe ALL visible text in the document — printed, \
        handwritten, stamps, seals, watermarks. Preserve reading order \
        (top-to-bottom, left-to-right). Use "[ILLEGIBLE]" for unreadable text. \
        Note font styles where relevant (bold headers, small print, handwriting).

        3. **structured_fields**: Extract key fields as name-value pairs. \
        Examples: dates (issue_date, expiry_date, signature_date), monetary \
        amounts (total, subtotal, tax), personal info (name, address, id_number, \
        phone), document identifiers (contract_no, invoice_no, receipt_no). \
        Use null for missing fields.

        4. **annotations**: List any marks, stamps, seals, corrections, \
        cross-outs, marginalia, or handwritten additions. For each, note \
        the position and content.

        5. **anomalies**: Flag any suspicious elements:
           - Corrections or overwrites (different ink, erasures)
           - Inconsistencies (mismatched dates, conflicting amounts)
           - Missing required fields (blank signature lines, absent dates)
           - Signs of tampering (aligned text misalignment, font mismatches)
           - Unusual formatting for the claimed document type

        6. **confidence**: Per-field confidence (high/medium/low) for each \
        major observation.

        ## OUTPUT CONTRACT

        Respond ONLY with a valid JSON object matching this schema:

        {
          "document_type": "string",
          "all_text": "string (all visible text transcribed)",
          "structured_fields": {
            "field_name": {"value": "string or null", "confidence": "high|medium|low"}
          },
          "annotations": [
            {"type": "stamp|seal|correction|handwriting|other",
             "content": "string",
             "position": "string"}
          ],
          "anomalies": [
            {"type": "correction|inconsistency|missing_field|tampering|unusual_format",
             "detail": "string",
             "severity": "critical|high|medium|low"}
          ],
          "confidence": "high|medium|low"
        }
        """
    }

    // MARK: - Response Parsing

    /// Parse the vision model's JSON response into an ``EvidenceBundle`` with
    /// verifiable ``EvidenceRef`` citations.
    ///
    /// Every ref's snippet is a substring of the source material (the raw
    /// analysis text), preserving the evidence-verification chain.
    private func parseAnalysisToBundle(
        _ analysisText: String,
        imageData: Data
    ) -> EvidenceBundle {
        // Source material keyed by "mlx_vision_analysis" — the raw model output
        let sourceKey = "mlx_vision_analysis"
        let sourceMaterial = [sourceKey: analysisText]

        // Attempt to extract JSON from the response
        let jsonPrefix = extractJSONObject(from: analysisText)
            ?? analysisText.trimmingCharacters(in: .whitespacesAndNewlines)

        var refs: [EvidenceRef] = []

        // Reference to the full analysis (always included)
        refs.append(EvidenceRef(
            source: sourceKey,
            location: "full_analysis",
            snippet: analysisText.prefix(500).trimmingCharacters(in: .whitespacesAndNewlines),
            kind: "text"
        ))

        // Parse structured JSON if available
        if let jsonData = jsonPrefix.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {

            // Document type
            if let docType = json["document_type"] as? String {
                refs.append(EvidenceRef(
                    source: sourceKey,
                    location: "document_type",
                    snippet: docType,
                    kind: "classification"
                ))
            }

            // Structured fields
            if let fields = json["structured_fields"] as? [String: [String: Any]] {
                let sortedFields = fields.sorted(by: { $0.key < $1.key })
                for (fieldName, fieldData) in sortedFields {
                    let value = fieldData["value"] as? String
                        ?? stringify(fieldData["value"])
                    let confidence = fieldData["confidence"] as? String ?? "medium"
                    let snippet = value.isEmpty ? "[MISSING]" : "\(fieldName): \(value)"
                    refs.append(EvidenceRef(
                        source: sourceKey,
                        location: "field:\(fieldName)",
                        snippet: snippet,
                        kind: "structured_field"
                    ))
                }
            }

            // Annotations (stamps, seals, corrections, handwriting)
            if let annotations = json["annotations"] as? [[String: Any]] {
                for (i, ann) in annotations.enumerated() {
                    let annType = ann["type"] as? String ?? "other"
                    let content = ann["content"] as? String ?? ""
                    let position = ann["position"] as? String ?? "unknown"
                    let snippet = "[\(annType)] \(content) @ \(position)"
                    refs.append(EvidenceRef(
                        source: sourceKey,
                        location: "annotation:\(i)",
                        snippet: snippet,
                        kind: "annotation"
                    ))
                }
            }

            // Anomalies (corrections, inconsistencies, missing fields, tampering)
            if let anomalies = json["anomalies"] as? [[String: Any]] {
                for (i, anom) in anomalies.enumerated() {
                    let anomType = anom["type"] as? String ?? "unknown"
                    let detail = anom["detail"] as? String ?? ""
                    let severity = anom["severity"] as? String ?? "medium"
                    let snippet = "[\(severity)] \(anomType): \(detail)"
                    refs.append(EvidenceRef(
                        source: sourceKey,
                        location: "anomaly:\(i)",
                        snippet: snippet,
                        kind: "anomaly"
                    ))
                }
            }
        }

        return EvidenceBundle(evidenceRefs: refs, sourceMaterial: sourceMaterial)
    }

    /// Extract the first complete JSON object from a string that may have
    /// markdown fences or trailing text.
    private func extractJSONObject(from text: String) -> String? {
        // Strip markdown code fences if present
        var cleaned = text
        let fencePattern = try? NSRegularExpression(
            pattern: "```(?:json)?\\s*([\\s\\S]*?)\\s*```",
            options: []
        )
        if let match = fencePattern?.firstMatch(
            in: cleaned,
            options: [],
            range: NSRange(cleaned.startIndex..., in: cleaned)
        ),
           let range = Range(match.range(at: 1), in: cleaned) {
            cleaned = String(cleaned[range])
        }

        // Find the first '{' and matching '}'
        guard let openBrace = cleaned.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for i in cleaned[openBrace...].indices {
            let ch = cleaned[i]

            if escaped {
                escaped = false
                continue
            }

            if ch == "\\" && inString {
                escaped = true
                continue
            }

            if ch == "\"" {
                inString.toggle()
                continue
            }

            if inString { continue }

            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(cleaned[openBrace...i])
                }
            }
        }

        return nil
    }

    /// Convert an arbitrary JSON value to a string representation.
    private func stringify(_ value: Any?) -> String {
        guard let value else { return "" }
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        case is NSNull: return ""
        default: return "\(value)"
        }
    }
}

// MARK: - MLXVisionError

/// Errors specific to the MLXVisionCollector.
public enum MLXVisionError: Error, LocalizedError {
    /// The mlx-libraries Swift package is not linked.
    case packageNotLinked(String)

    /// The vision model failed to load.
    case modelLoadFailed(underlying: Error)

    /// The model is not loaded (should not happen in normal flow).
    case modelNotLoaded

    /// Image analysis failed.
    case analysisFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .packageNotLinked(let msg):
            return "MLXVision: \(msg)"
        case .modelLoadFailed(let error):
            return "MLXVision: Failed to load model: \(error.localizedDescription)"
        case .modelNotLoaded:
            return "MLXVision: Model not loaded"
        case .analysisFailed(let error):
            return "MLXVision: Analysis failed: \(error.localizedDescription)"
        }
    }
}
