import Foundation

// MARK: - CloudLLMBackend

/// 云端 LLM 后端协议（OpenAI 兼容接口）。
///
/// ## 预期接入的 API 表面（OpenAI Chat Completions 兼容）
///
/// 真实实现将调用：
/// ```
/// POST {baseURL}/chat/completions
/// Authorization: Bearer {apiKey}
/// Content-Type: application/json
///
/// {
///   "model": "gpt-4o-mini",
///   "messages": [
///     {"role": "system", "content": "你是劳动法律师助理……"},
///     {"role": "user", "content": "根据以下证据内容……"}
///   ],
///   "temperature": 0.2
/// }
/// ```
///
/// 成功响应取 `choices[0].message.content` 作为返回文本。
///
/// ## 接入约定
/// - 所有请求必须走 `URLSession`，支持超时与重试；
/// - 用户隐私：OCR 证据文字属于敏感数据，默认不上传；仅当用户明确开启
///   「云端增强」且同意数据使用时才允许调用本协议；
/// - 输出期望为结构化 JSON（如 `{"proofContent": "...", "proofPurpose": "..."}`），
///   由调用方按 LawAgent 的 Reflection 校验流程逐字核对后再写入目录。
///
/// 当前阶段仅提供协议与 Mock 实现，不发起真实网络请求。
public protocol CloudLLMBackend: Sendable {
    /// 对话补全。`messages` 为 OpenAI chat completions 格式：
    /// 每个元素形如 `["role": "system|user|assistant", "content": "…"]`。
    func chat(messages: [[String: String]]) async throws -> String
}

// MARK: - CloudEndpoint

/// OpenAI 兼容服务的端点配置（供未来真实实现使用）。
public struct CloudEndpoint: Sendable, Equatable {
    /// 服务根地址，如 `https://api.openai.com/v1`。
    public var baseURL: URL
    /// 鉴权密钥（仅保存在用户本地设置，不写入日志）。
    public var apiKey: String
    /// 模型名，如 `gpt-4o-mini`、`qwen-plus` 等。
    public var model: String

    public init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    /// OpenAI 官方端点示例。
    public static let openAI = CloudEndpoint(
        baseURL: URL(string: "https://api.openai.com/v1")!,
        apiKey: "",
        model: "gpt-4o-mini"
    )

    /// 任意 OpenAI 兼容端点（如本地 vLLM、Ollama、通义等）。
    public static func compatible(baseURL: URL, apiKey: String, model: String) -> CloudEndpoint {
        CloudEndpoint(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}

// MARK: - MockCloudLLM

/// 云端 LLM 的 Mock 实现：用于测试与 UI 预览。
///
/// 行为完全确定、无网络请求：
/// - 若最后一条 user 消息包含「证明内容」类请求，返回结构化的证据草稿 JSON；
/// - 否则返回一段固定中文应答，便于断言。
public final class MockCloudLLM: CloudLLMBackend {

    /// 内置证据草稿：金额与日期占位符由调用方替换为真实原文值。
    public static let draftTemplate = """
    {
      "proofContent": "该证据载明金额与日期等关键要素（草稿），请以原文逐字核对后使用。",
      "proofPurpose": "证明相关事实，支持对应仲裁请求。"
    }
    """

    public init() {}

    public func chat(messages: [[String: String]]) async throws -> String {
        // 取最后一条 user 消息作为请求内容
        let lastUserContent = messages.reversed()
            .first { $0["role"] == "user" }?["content"] ?? ""

        if lastUserContent.contains("证明内容") || lastUserContent.contains("证据") {
            return Self.draftTemplate
        }
        return "已收到请求。当前为离线 Mock 模式，未接入真实云端模型；请在设置中配置云端端点。"
    }
}
