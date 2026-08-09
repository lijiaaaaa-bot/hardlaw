import Foundation
import HardlawKit

// MARK: - Local MLX Client

/// Talks to a Mac running `scripts/mlx_judge_server.py` on the local network.
/// LLM inference happens on the Mac GPU; iPhone only sends/receives text.
/// Zero cloud — data never leaves the LAN.
public actor LocalMLXClient: LLMBackend {

    private let baseURL: URL
    private let session: URLSession

    /// - Parameter host: Mac's local IP or hostname (e.g., "192.168.1.5" or "My-Mac.local")
    public init(host: String = "127.0.0.1", port: Int = 8766) {
        self.baseURL = URL(string: "http://\(host):\(port)/judge")!
        self.session = URLSession(configuration: .default)
    }

    public func judge(_ prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120 // 0.5B model on GPU: 10-30s typical
        request.httpBody = try JSONEncoder().encode(JudgeRequest(prompt: prompt))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LocalMLXError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LocalMLXError.serverError(httpResponse.statusCode, body)
        }
        let result = try JSONDecoder().decode(JudgeResponse.self, from: data)
        return result.text
    }

    /// Quick health check — is the Mac server reachable?
    public func ping() async -> Bool {
        guard let url = URL(string: baseURL.absoluteString.replacingOccurrences(of: "/judge", with: "/")) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

private struct JudgeRequest: Codable {
    let prompt: String
}

private struct JudgeResponse: Codable {
    let text: String
}

public enum LocalMLXError: Error {
    case invalidResponse
    case serverError(Int, String)
}


