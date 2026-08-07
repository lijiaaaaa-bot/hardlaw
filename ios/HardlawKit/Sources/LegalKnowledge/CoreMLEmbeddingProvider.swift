import CoreML
import Foundation

// MARK: - CoreML EmbeddingProvider

/// Embedding provider using a CoreML-converted `BAAI/bge-small-zh-v1.5` model.
///
/// ## Setup
///
/// 1. Run `scripts/convert_bge_to_coreml.py` (requires Python + coremltools)
/// 2. This produces `bge-small-zh-v1.5.mlpackage` (CoreML model) and
///    `bge-small-zh-v1.5-tokenizer/` (vocab.txt + tokenizer_config.json)
/// 3. Both are bundled in `HardlawKit/Resources/` via `project.yml`
/// 4. Xcode compiles `.mlpackage` → `.mlmodelc` at build time
///
/// ## Key design decisions
///
/// - Mean pooling (not CLS token) — handles variable-length input via `RangeDim`
/// - L2 normalization applied to output vectors (contract required by `LawIndex`)
/// - Tokenizer uses `huggingface/swift-transformers` with `vocab.txt` from the
///   exact same HuggingFace repo as training (guarantees token match)
/// - Actor-isolated for thread safety (CoreML models are not Sendable)
public actor CoreMLEmbeddingProvider: EmbeddingProvider {

    // MARK: - Properties

    /// Output dimension of bge-small-zh-v1.5.
    public let dimension = 512

    /// The compiled CoreML model.
    private var model: MLModel?

    /// Whether the model has been loaded.
    private var isLoaded = false

    // MARK: - Types

    public enum LoadError: Error, LocalizedError {
        case modelNotFound
        case tokenizerNotFound
        case compilationFailed(Error)
        case predictionFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "bge-small-zh-v1.5.mlmodelc not found in bundle"
            case .tokenizerNotFound:
                return "bge-small-zh-v1.5-tokenizer/ not found in bundle"
            case .compilationFailed(let error):
                return "CoreML model compilation failed: \(error.localizedDescription)"
            case .predictionFailed(let error):
                return "CoreML prediction failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Init

    public init() {}

    // MARK: - Loading

    /// Load the CoreML model from the app bundle.
    ///
    /// Xcode compiles `.mlpackage` → `.mlmodelc` at build time, so we load
    /// the compiled version. Call this early (e.g., on app launch) to avoid
    /// first-query latency.
    public func load() async throws {
        guard !isLoaded else { return }

        guard let compiledURL = Bundle.main.url(
            forResource: "bge-small-zh-v1.5",
            withExtension: "mlmodelc"
        ) else {
            throw LoadError.modelNotFound
        }

        do {
            self.model = try MLModel(contentsOf: compiledURL)
            self.isLoaded = true
        } catch {
            throw LoadError.compilationFailed(error)
        }
    }

    // MARK: - EmbeddingProvider

    public func embed(_ text: String) async throws -> [Float] {
        // Lazy-load on first use
        if !isLoaded {
            try await load()
        }

        guard let model = model else {
            throw LoadError.modelNotFound
        }

        // Tokenize using swift-transformers
        let encoded = try await CoreMLTokenizer.shared.encode(text: text)

        // Build input feature provider (encoded already provides MLMultiArray)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": encoded.inputIds,
            "attention_mask": encoded.attentionMask,
        ])

        // Run inference
        let output: MLFeatureProvider
        do {
            output = try await model.prediction(from: input)
        } catch {
            throw LoadError.predictionFailed(error)
        }

        // Extract embedding vector
        guard
            let embedding = output.featureValue(for: "sentence_embedding")?.multiArrayValue
        else {
            throw LoadError.predictionFailed(
                NSError(domain: "CoreMLEmbeddingProvider", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing 'sentence_embedding' in model output"])
            )
        }

        // Convert MLMultiArray → [Float]
        var vector = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension {
            vector[i] = embedding[i].floatValue
        }

        // L2-normalize (contract required by LawIndex for inner-product similarity)
        return l2Normalize(vector)
    }

    // MARK: - L2 Normalization

    /// L2-normalize a vector to unit length.
    ///
    /// The document vectors are pre-normalized. Query vectors MUST also be
    /// normalized for inner-product search to work as cosine similarity.
    private func l2Normalize(_ vector: [Float]) -> [Float] {
        let squaredSum = vector.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(squaredSum)
        guard norm > 1e-12 else { return vector }
        return vector.map { $0 / norm }
    }
}

// MARK: - Tokenizer Helpers

/// Tokenizer wrapper using `huggingface/swift-transformers`.
///
/// Loads `vocab.txt` and `tokenizer_config.json` from the bundled
/// `bge-small-zh-v1.5-tokenizer/` directory.
private actor CoreMLTokenizer {
    static let shared = CoreMLTokenizer()

    private var tokenizer: Tokenizer?

    private enum TokenizerError: Error {
        case notFound
    }

    /// Tokenized output with input IDs and attention mask.
    struct TokenOutput {
        let inputIds: MLMultiArray
        let attentionMask: MLMultiArray
    }

    func encode(text: String) async throws -> TokenOutput {
        if tokenizer == nil {
            guard let tokenizerURL = Bundle.main.url(
                forResource: "bge-small-zh-v1.5-tokenizer",
                withExtension: nil
            ) else {
                throw CoreMLEmbeddingProvider.LoadError.tokenizerNotFound
            }
            // AutoTokenizer from swift-transformers loads config + vocab.txt
            self.tokenizer = try await AutoTokenizer.from(modelPath: tokenizerURL)
        }

        guard let tok = tokenizer else {
            throw TokenizerError.notFound
        }

        // Encode text (handles Chinese via BasicTokenizer → WordpieceTokenizer)
        let encoded = tok.encode(text: text)
        let maxLen = min(512, encoded.inputIds.count)
        let paddedIds = encoded.inputIds.prefix(maxLen) + Array(repeating: 0, count: max(0, 512 - encoded.inputIds.count))
        let paddedMask = encoded.attentionMask.prefix(maxLen) + Array(repeating: 0, count: max(0, 512 - encoded.attentionMask.count))

        // swift-transformers doesn't pad to maxLength by default; we pad manually
        let inputIds = try MLMultiArray(shape: [1, NSNumber(value: 512)], dataType: .int32)
        let attentionMask = try MLMultiArray(shape: [1, NSNumber(value: 512)], dataType: .int32)

        for i in 0..<512 {
            inputIds[i] = NSNumber(value: paddedIds[i])
            attentionMask[i] = NSNumber(value: paddedMask[i])
        }

        return TokenOutput(inputIds: inputIds, attentionMask: attentionMask)
    }
}

// MARK: - MLMultiArray Convenience

private extension MLMultiArray {
    /// Create an MLMultiArray from an [NSNumber] shape specification.
    /// Used to create 1x512 arrays for tokenizer output.
    static func tokenArray(count: Int, dataType: MLMultiArrayDataType = .int32) throws -> MLMultiArray {
        try MLMultiArray(
            shape: [1, NSNumber(value: count)],
            dataType: dataType
        )
    }
}
