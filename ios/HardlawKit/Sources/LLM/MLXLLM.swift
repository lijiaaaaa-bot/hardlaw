import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MARK: - MLXLLM (v3.x)

/// On-device LLM judge — MLX via Metal GPU.
/// Model: Qwen2.5-0.5B-Instruct-4bit (~500MB, cached after first download).
public actor MLXLLM: LLMBackend {

    private var container: ModelContainer?
    private let modelID: String

    public init(modelID: String = "mlx-community/Qwen2.5-0.5B-Instruct-4bit") {
        self.modelID = modelID
    }

    public func judge(_ prompt: String) async throws -> String {
        let c: ModelContainer
        if let m = container { c = m }
        else {
            let id = modelID
            c = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: .init(id: id),
                progressHandler: { p in
                    print("[MLXLLM] Downloading: \(Int(p.fractionCompleted * 100))%")
                }
            )
            container = c
            print("[MLXLLM] Ready.")
        }
        let session = ChatSession(c)
        return try await session.respond(to: prompt)
    }
}
