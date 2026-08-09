import CoreML
import Foundation

/// iPhone ANE 上的 BGE-small-zh-v1.5 语义嵌入。
/// 模型由 Xcode 从 .mlpackage 编译为 .mlmodelc。
public final class CoreMLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let dimension = 512
    private nonisolated(unsafe) var model: MLModel?
    private var vocab: [String: Int] = [:]
    private var loaded = false

    public init() {}

    public func embed(_ text: String) async throws -> [Float] {
        // Load once
        if !loaded, let url = Bundle.main.url(forResource: "BGE-small-zh", withExtension: "mlmodelc") {
            model = try MLModel(contentsOf: url)
            if let v = Bundle.main.url(forResource: "vocab", withExtension: "txt"),
               let c = try? String(contentsOf: v, encoding: .utf8) {
                for (i, t) in c.components(separatedBy: .newlines).enumerated() where !t.isEmpty { vocab[t] = i }
            }
            loaded = true
        }
        guard let m = model else { throw LoadError.modelNotFound }

        let ids = tokenize(text)
        let input = try MLMultiArray(shape: [1, NSNumber(value: 512)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: 512)], dataType: .float32)
        for i in 0..<512 {
            input[i] = NSNumber(value: Int32(i < ids.count ? ids[i] : 0))
            mask[i] = NSNumber(value: Float(i < ids.count ? 1.0 : 0.0))
        }
        let pred = try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": input, "attention_mask": mask
        ]))
        guard let emb = pred.featureValue(for: "sentence_embedding")?.multiArrayValue else {
            throw LoadError.predictionFailed(NSError(domain: "", code: -1))
        }
        var v = [Float](repeating: 0, count: dimension), n: Float = 0
        for i in 0..<dimension { let x = emb[i].floatValue; v[i] = x; n += x * x }
        n = sqrt(n)
        if n > 0 { for i in 0..<dimension { v[i] /= n } }
        return v
    }

    private func tokenize(_ text: String) -> [Int] {
        var ids: [Int] = [101]
        for char in text { ids.append(vocab[String(char)] ?? 100) }
        ids.append(102)
        if ids.count > 512 { ids = Array(ids.prefix(511)) + [102] }
        return ids
    }

    public enum LoadError: Error { case modelNotFound; case predictionFailed(Error) }
}
