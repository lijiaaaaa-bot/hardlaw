import Foundation
import HardlawKit

// MARK: - Ollama LLM Backend

/// Calls a local Ollama instance. Model runs on this Mac's GPU.
/// Zero cloud — data stays on this machine.
///
/// Dual-model architecture (Haidian pattern):
///   Planner (large): decomposes goal → structured step list
///   Judge (small):   executes each step via Court.hear()
public actor OllamaClient: LLMBackend {

    private let baseURL: URL
    private let model: String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(model: String = "qwen3:0.6b", host: String = "127.0.0.1", port: Int = 11434) {
        self.model = model
        self.baseURL = URL(string: "http://\(host):\(port)/api")!
        self.session = URLSession(configuration: .default)
    }

    // MARK: - LLMBackend

    public func judge(_ prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body = OllamaChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            stream: false,
            options: .init(temperature: 0.1, num_predict: 500)
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw OllamaError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        let result = try decoder.decode(OllamaChatResponse.self, from: data)
        return result.message.content
    }

    // MARK: - Planner (large model for goal decomposition)

    /// Use a larger model to decompose a high-level goal into structured steps.
    /// This is the "Planner" of the dual-model architecture.
    public func plan(goal: String, context: String) async throws -> OllamaPlan {
        let prompt = """
        你是一个法律案件审查规划器。根据用户的目标和案件背景，将任务分解为具体的、可验证的步骤。

        ## 用户目标
        \(goal)

        ## 案件背景
        \(context)

        ## 要求
        返回一个 JSON 数组，每个元素是一个步骤。格式：
        {
          "steps": [
            {
              "name": "步骤中文名称",
              "detail": "具体要检查什么",
              "kind": "generateCatalog|verifyCitations|detectGaps|checkConsistency",
              "reasoning": "为什么需要这一步"
            }
          ]
        }

        只返回 JSON，不要其他文字。
        """

        var request = URLRequest(url: baseURL.appendingPathComponent("chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let body = OllamaChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            stream: false,
            options: .init(temperature: 0.1, num_predict: 2000)
        )
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else {
            throw OllamaError.serverError(String(data: data, encoding: .utf8) ?? "")
        }
        let result = try decoder.decode(OllamaChatResponse.self, from: data)
        let json = extractJSON(from: result.message.content)
        return try decoder.decode(OllamaPlan.self, from: json.data(using: .utf8)!)
    }

    private func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}

// MARK: - Data Types

struct OllamaChatRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let options: OllamaOptions

    struct OllamaMessage: Codable {
        let role: String
        let content: String
    }

    struct OllamaOptions: Codable {
        let temperature: Double?
        let num_predict: Int?
    }
}

struct OllamaChatResponse: Codable {
    let message: OllamaMessageResponse
    struct OllamaMessageResponse: Codable {
        let content: String
    }
}

/// Planner output: structured steps for goal execution.
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
