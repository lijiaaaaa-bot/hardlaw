import Foundation

// MARK: - LawChunk

/// A single indexed article from a Chinese law document.
/// Mirrors Python `hardlaw.legal_knowledge.LawChunk`.
public struct LawChunk: Codable, Equatable, Sendable, Identifiable {
    /// Unique chunk ID, e.g. "劳动法/第三十一条"
    public var id: String
    /// Law document ID, e.g. "劳动法"
    public var lawID: String
    /// Full Chinese title of the law
    public var lawTitle: String
    /// Top-level category, e.g. "社会法"
    public var category: String
    /// Article number, e.g. "第三十一条" (empty string for preamble chunks)
    public var articleNum: String
    /// Chapter/section heading this chunk belongs to
    public var heading: String
    /// The full text of this chunk
    public var text: String

    enum CodingKeys: String, CodingKey {
        case id, lawID = "law_id", lawTitle = "law_title"
        case category, articleNum = "article_num", heading, text
    }
}

// MARK: - LawSearchResult

/// A ranked search result combining a chunk with its search score.
public struct LawSearchResult: Sendable {
    public let chunk: LawChunk
    public let score: Float

    public init(chunk: LawChunk, score: Float) {
        self.chunk = chunk
        self.score = score
    }
}
