import Foundation
import HardlawKit

// MARK: - Ollama 本地模型客户端

/// Haidian 模式：本地 Ollama 双模型驱动 Goal-Driven 循环。
///
/// 架构：
///   Planner (大模型):  分解 Goal → 结构化步骤 JSON
///   Judge  (小模型):   执行每个步骤，生成 Verdict
///
/// Ollama 已在 Mac 上运行，模型已在本地磁盘。零网络，零云端。
public actor OllamaClient: LLMBackend {

    private let baseURL = URL(string: "http://127.0.0.1:11434/api")!
    private let model: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let session: URLSession

    public init(model: String) {
        self.model = model
        self.session = URLSession(configuration: .default)
    }

    // MARK: - LLMBackend (Judge)

    public func judge(_ prompt: String) async throws -> String {
        try await chat(prompt, temperature: 0.1, maxTokens: 500)
    }

    // MARK: - Planner

    /// 用大模型分解 Goal 为结构化步骤。
    public func plan(goal: String, context: String) async throws -> OllamaPlan {
        let prompt = """
        你是法律案件审查规划器。根据用户目标和案件信息，将任务分解为具体的、可验证的审查步骤。

        用户目标：\(goal)
        案件信息：\(context)

        返回 JSON（只返回 JSON，不要其他文字）：
        {"steps":[{"name":"步骤名称","detail":"具体检查内容","kind":"verifyCitations|detectGaps|checkConsistency","reasoning":"为什么需要这步"}]}
        """
        let text = try await chat(prompt, temperature: 0.1, maxTokens: 2000)
        let json = extractJSON(from: text)
        return try decoder.decode(OllamaPlan.self, from: json.data(using: .utf8)!)
    }

    // MARK: - Core

    private func chat(_ prompt: String, temperature: Double, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "options": ["temperature": temperature, "num_predict": maxTokens]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw OllamaError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        let msg = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = msg?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaError.serverError("unexpected response format")
        }
        return content
    }

    private func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}

// MARK: - Types

public struct OllamaPlan: Codable, Sendable {
    public let steps: [OllamaPlanStep]
}

public struct OllamaPlanStep: Codable, Sendable {
    public let name: String
    public let detail: String
    public let kind: String
    public let reasoning: String
}

public enum OllamaError: Error {
    case serverError(String)
}
