import Foundation

// MARK: - MLXLLM (requires mlx-libraries package)

/// On-device MLX LLM backend for text judgment.
///
/// Loads a quantized model (Qwen2.5-0.5B-Instruct 4-bit by default) via the
/// `mlx-libraries` package and implements the `LLMBackend` protocol so the
/// Court can use it directly as a drop-in judge.
///
/// ## Model requirements
/// - 4 GB+ device RAM (checked at init via ``CapabilityDetector/canRunMLXLLM()``)
/// - ~500 MB storage for the 4-bit model weights (auto-downloaded on first use)
/// - iOS 17.0+ (MLX Swift runtime requirement)
///
/// ## Thread safety
/// MLXLLM is an `actor`, so all state access is serialized. The underlying
/// `ModelContainer` is also an actor — the `perform` block runs on the
/// container's serial executor.
///
/// ## Fail-closed behavior
/// Any error (model load failure, generation timeout, OOM) is thrown to the
/// caller. The Court's ``Court/invokeJudge(ctx:step:)`` catches these and
/// returns a ``Verdict`` with `refuted: true, blocking: true`, preserving the
/// hardlaw fail-closed guarantee.
///
/// ## Usage
/// ```swift
/// let llm = MLXLLM()
/// let court = Court(statutes: myStatutes, procedure: myProcedure, llm: llm)
/// let result = await court.hear(caseData: [...])
/// ```
public actor MLXLLM: LLMBackend {

    // MARK: - Configuration

    /// HuggingFace model identifier for the text judgment model.
    /// Default: Qwen2.5-0.5B-Instruct quantized to 4 bits — small enough for
    /// iPhone, capable enough for compliance judgment tasks.
    private let modelId: String

    /// Maximum tokens to generate in a single judgment call.
    private let maxTokens: Int

    /// Sampling temperature. 0.0 = deterministic (recommended for judgment).
    private let temperature: Float

    /// System prompt prepended to every judgment prompt.
    private let systemPrompt: String

    // MARK: - State

    /// Lazily-loaded model container. Nil until first `judge()` call.
    private var modelContainer: Any?  // ModelContainer (opaque until mlx-libraries linked)

    /// Whether the model container has been loaded.
    private var isLoaded: Bool = false

    /// Error captured during load, re-thrown on every subsequent call.
    private var loadError: Error?

    // MARK: - Initialization

    /// Create an MLX-powered LLM judge.
    ///
    /// - Parameters:
    ///   - modelId: HuggingFace model ID (default: Qwen2.5-0.5B-Instruct 4-bit)
    ///   - maxTokens: Maximum output tokens per judgment (default: 1024)
    ///   - temperature: Sampling temperature, 0.0 for deterministic (default: 0.0)
    public init(
        modelId: String = "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        maxTokens: Int = 1024,
        temperature: Float = 0.0
    ) {
        self.modelId = modelId
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.systemPrompt = """
        You are a compliance court judge applying hard constraints to agent output. \
        You must be precise, evidence-based, and default to rejection when uncertain. \
        Every finding MUST cite specific evidence. \
        Do NOT author new evidence — only audit what is provided. \
        Output valid JSON matching the OUTPUT CONTRACT.
        """
    }

    // MARK: - LLMBackend

    /// Submit a judgment prompt and receive raw LLM output.
    ///
    /// The returned string is passed directly to `VerdictParser.parse()` by the
    /// Court. It should contain a JSON verdict object followed by a terminal
    /// token ("Refuted" or "Not Refuted").
    ///
    /// - Parameter prompt: The full judgment prompt built by the Court
    /// - Returns: Raw model output (JSON verdict + terminal token)
    /// - Throws: `MLXLLMError` if the model fails to load or generate
    public func judge(_ prompt: String) async throws -> String {
        // If a previous load failed, re-throw that error
        if let loadError {
            throw loadError
        }

        // Lazy-load the model on first call
        if !isLoaded {
            do {
                try await loadModel()
                isLoaded = true
            } catch {
                loadError = MLXLLMError.modelLoadFailed(underlying: error)
                throw loadError!
            }
        }

        // Generate
        do {
            return try await generate(prompt: prompt)
        } catch {
            throw MLXLLMError.generationFailed(underlying: error)
        }
    }

    // MARK: - Model Lifecycle

    /// Load the MLX model container.
    ///
    /// Downloads model weights on first run (~500 MB), caches them locally,
    /// and initializes the MLX inference engine.
    ///
    /// When the `mlx-libraries` Swift package is linked, replace the body of
    /// this method with the real MLX load call and remove the `#if false`
    /// conditional compilation block.
    private func loadModel() async throws {
        // --- Real implementation (enable when mlx-libraries is linked) ---
        // Replace `#if false` with `#if canImport(MLXLLM)` once the
        // mlx-libraries package is added to project.yml dependencies.
        //
        // import MLXLLM
        // import MLXLMCommon
        //
        // let config = ModelConfiguration.configuration(id: modelId)
        // modelContainer = try await ModelContainer.loadModelContainer(
        //     configuration: config
        // )

        #if false
        // This block will compile once mlx-libraries is added as a dependency.
        // See project.yml for the package reference.
        let config = ModelConfiguration.configuration(id: modelId)
        let container = try await ModelContainer.loadModelContainer(
            configuration: config
        )
        modelContainer = container
        #else
        // Stub: throws a clear error until mlx-libraries is linked.
        // This preserves the API contract so the rest of the codebase can
        // reference MLXLLM without conditional compilation.
        throw MLXLLMError.packageNotLinked(
            "mlx-libraries package not linked. Add it to project.yml dependencies."
        )
        #endif
    }

    /// Run inference with the loaded model.
    ///
    /// When mlx-libraries is linked, replace the body of this method with the
    /// real MLX generation call.
    private func generate(prompt: String) async throws -> String {
        // --- Real implementation (enable when mlx-libraries is linked) ---
        // Replace `#if false` with `#if canImport(MLXLLM)` once the
        // mlx-libraries package is added to project.yml dependencies.
        //
        // guard let container = modelContainer as? ModelContainer else {
        //     throw MLXLLMError.modelNotLoaded
        // }
        //
        // return try await container.perform { context in
        //     let messages: [[String: String]] = [
        //         ["role": "system", "content": systemPrompt],
        //         ["role": "user", "content": prompt],
        //     ]
        //     let input = try await context.processor.prepare(
        //         input: .messages(messages)
        //     )
        //     let result = try await MLXLLM.generate(
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
            throw MLXLLMError.modelNotLoaded
        }

        return try await container.perform { context in
            let messages: [[String: String]] = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt],
            ]
            let input = try await context.processor.prepare(
                input: .messages(messages)
            )
            let result = try await MLXLLM.generate(
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
        throw MLXLLMError.packageNotLinked(
            "mlx-libraries package not linked. Add it to project.yml dependencies."
        )
        #endif
    }

    // MARK: - Resource Management

    /// Release the loaded model from memory.
    ///
    /// Call this when the Court is no longer needed (e.g., app backgrounding)
    /// to free ~500 MB of RAM. The model will be reloaded on the next `judge()`
    /// call.
    public func unload() {
        modelContainer = nil
        isLoaded = false
        loadError = nil
    }

    /// Whether the model is currently loaded in memory.
    public var loaded: Bool { isLoaded && loadError == nil }
}

// MARK: - MLXLLMError

/// Errors specific to the MLXLLM backend.
public enum MLXLLMError: Error, LocalizedError {
    /// The mlx-libraries Swift package is not linked.
    case packageNotLinked(String)

    /// The model failed to load (download, memory, or format issue).
    case modelLoadFailed(underlying: Error)

    /// The model is not loaded (should not happen in normal flow).
    case modelNotLoaded

    /// Text generation failed (OOM, timeout, or inference error).
    case generationFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .packageNotLinked(let msg):
            return "MLXLLM: \(msg)"
        case .modelLoadFailed(let error):
            return "MLXLLM: Failed to load model '\(error.localizedDescription)'"
        case .modelNotLoaded:
            return "MLXLLM: Model not loaded"
        case .generationFailed(let error):
            return "MLXLLM: Generation failed: \(error.localizedDescription)"
        }
    }
}
