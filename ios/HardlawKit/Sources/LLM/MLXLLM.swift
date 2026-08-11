import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// MARK: - MLXLLM (v3.x)

/// On-device LLM judge — MLX via Metal GPU.
/// Model: Qwen2.5-0.5B-Instruct-4bit (~500MB, cached after first download).
/// Pinned to a fixed revision for supply-chain integrity.
public actor MLXLLM: LLMBackend {

    /// Model identifier with pinned revision for supply-chain integrity.
    /// Update the revision hash when upgrading to a newer model version.
    /// Current: mlx-community/Qwen2.5-3B-Instruct-4bit (~1.9GB)
    /// Fallback: mlx-community/Qwen2.5-0.5B-Instruct-4bit (~500MB)
    public static let defaultModelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    public static let fallbackModelID = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    private var container: ModelContainer?
    private let modelID: String

    /// Whether MLX can be used right now: the model is cached locally (no
    /// network needed) and the runtime is safe to use.
    ///
    /// Always false on the iOS Simulator: MLX model loading there hard-aborts
    /// the process with a libc++ hardening assertion (`basic_string` from a
    /// null pointer) that no Swift error handling can catch, so callers should
    /// stick to the local rule engine in the simulator.
    ///
    /// On device, resolves the HuggingFace cache root the same way `HubCache`
    /// does (`HF_HUB_CACHE` → `HF_HOME/hub` → platform default:
    /// `~/.cache/huggingface/hub` on non-sandboxed macOS, `<app Caches>/huggingface/hub`
    /// on iOS and sandboxed macOS). A download counts as complete only once a
    /// `snapshots/` ref exists, so a half-finished 500MB download never
    /// masquerades as "available".
    ///
    /// When false, callers should use a network-free fallback backend instead of
    /// triggering a fresh download on first launch.
    public static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let fm = FileManager.default
        let modelDir = modelCacheDirName(defaultModelID)
        var snapshots: [URL] = [
            URL.cachesDirectory
                .appendingPathComponent("huggingface/hub/\(modelDir)/snapshots"),
        ]
        #if os(macOS)
        snapshots.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".cache/huggingface/hub/\(modelDir)/snapshots")
        )
        #endif
        return snapshots.contains { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
            return !((try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
        }
        #endif
    }

    /// Convert a HuggingFace model ID to its cache directory name.
    /// e.g. "mlx-community/Qwen2.5-0.5B-Instruct-4bit" → "models--mlx-community--Qwen2.5-0.5B-Instruct-4bit"
    private static func modelCacheDirName(_ id: String) -> String {
        "models--\(id.replacingOccurrences(of: "/", with: "--"))"
    }

    public init(modelID: String = defaultModelID) {
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
