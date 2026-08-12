import CoreML
import Foundation

// MARK: - CoreMLEmbeddingProvider

/// On-device semantic query embedding via CoreML (BGE-small-zh-v1.5).
///
/// The compiled `BGE-small-zh.mlmodelc` and its `vocab.txt` are generated
/// offline from BGE-small-zh-v1.5 (see `docs/embedding-provider-plan.md`)
/// and bundled with the app. Until the model asset is added to the bundle,
/// `embed()` throws `LoadError.modelNotFound`, and `LawIndex.search()`
/// transparently falls back to keyword-only search.
///
/// Tokenization is dependency-free: a BERT-style char-level tokenizer
/// (`[CLS]` + per-character tokens + `[SEP]`) over the bundled `vocab.txt`.
/// This mirrors the classic BERT Chinese recipe — CJK characters are split
/// into individual tokens and out-of-vocabulary characters map to `[UNK]`.
/// No `swift-transformers` package is required.
public final class CoreMLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    /// Output dimension of BGE-small-zh-v1.5.
    public let dimension = 512

    private let bundle: Bundle
    private let lock = NSLock()
    private var model: MLModel?
    private var vocab: [String: Int] = [:]
    private var loadAttempted = false

    public init() {
        self.bundle = .main
    }

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    /// Encode a Chinese query into an L2-normalized 512-dimension vector.
    public func embed(_ text: String) async throws -> [Float] {
        let (loadedModel, loadedVocab) = try loadIfNeeded()
        let ids = Self.tokenize(text, vocab: loadedVocab)

        // Fixed 512-token input: valid for both fixed-shape and
        // RangeDim-flexible CoreML models.
        let input = try MLMultiArray(shape: [1, NSNumber(value: 512)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: 512)], dataType: .float32)
        for i in 0..<512 {
            input[i] = NSNumber(value: Int32(i < ids.count ? ids[i] : 0))
            mask[i] = NSNumber(value: Float(i < ids.count ? 1.0 : 0.0))
        }

        let prediction = try await loadedModel.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": input,
                "attention_mask": mask,
            ])
        )
        guard let output = prediction.featureValue(for: "sentence_embedding")?.multiArrayValue else {
            throw LoadError.predictionFailed(nil)
        }

        // Extract embedding and L2-normalize (protocol contract).
        var vector = [Float](repeating: 0, count: dimension)
        var sumOfSquares: Float = 0
        for i in 0..<dimension {
            let value = output[i].floatValue
            vector[i] = value
            sumOfSquares += value * value
        }
        let norm = sqrt(sumOfSquares)
        if norm > 0 {
            for i in 0..<dimension {
                vector[i] /= norm
            }
        }
        return vector
    }

    // MARK: - Loading

    private func loadIfNeeded() throws -> (model: MLModel, vocab: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        if !loadAttempted {
            loadAttempted = true

            // Compiled CoreML model (Xcode compiles .mlpackage → .mlmodelc).
            // The offline conversion emits bge-small-zh-v1.5; accept the
            // BGE-small-zh spelling too.
            let modelName = ["BGE-small-zh", "bge-small-zh-v1.5"].first {
                bundle.url(forResource: $0, withExtension: "mlmodelc") != nil
            }
            if let modelName,
               let modelURL = bundle.url(forResource: modelName, withExtension: "mlmodelc"),
               let loaded = try? MLModel(contentsOf: modelURL) {
                model = loaded
            }

            // BERT vocabulary — bundle root first, then LegalKnowledge folder.
            var vocabURL = bundle.url(forResource: "vocab", withExtension: "txt")
            if vocabURL == nil,
               let dir = bundle.url(forResource: "LegalKnowledge", withExtension: nil) {
                vocabURL = dir.appendingPathComponent("vocab.txt")
            }
            if let vocabURL,
               let text = try? String(contentsOf: vocabURL, encoding: .utf8) {
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !token.isEmpty {
                        vocab[token] = index
                    }
                }
            }
        }

        guard let loadedModel = model else { throw LoadError.modelNotFound }
        guard !vocab.isEmpty else { throw LoadError.tokenizerNotFound }
        return (loadedModel, vocab)
    }

    // MARK: - Tokenization

    /// BERT special-token IDs (BGE-small-zh-v1.5 follows the Chinese BERT
    /// vocab convention: [CLS]=101, [SEP]=102, [UNK]=100).
    private static let clsToken = 101
    private static let sepToken = 102
    private static let unkToken = 100
    private static let maxTokens = 512

    /// BERT-style char-level tokenization: `[CLS]` + one token per character
    /// + `[SEP]`, truncated to 512 tokens with the `[SEP]` preserved.
    static func tokenize(_ text: String, vocab: [String: Int]) -> [Int] {
        var ids = [clsToken]
        for character in text {
            ids.append(vocab[String(character)] ?? unkToken)
        }
        ids.append(sepToken)
        if ids.count > maxTokens {
            ids = Array(ids.prefix(maxTokens - 1)) + [sepToken]
        }
        return ids
    }
}

// MARK: - Errors

extension CoreMLEmbeddingProvider {
    public enum LoadError: Error {
        case modelNotFound
        case tokenizerNotFound
        case predictionFailed(Error?)
    }
}
