import Foundation
import NaturalLanguage

// MARK: - LawStore

/// File-based repository of Chinese legal documents, loaded from the app bundle.
///
/// Parses pre-exported JSON chunk metadata. Markdown files are not parsed at
/// runtime — the Python `export_for_ios.py` script handles parsing and exports
/// structured JSON that the app reads directly.
///
/// ## Keyword Search
///
/// Uses Apple's `NLTokenizer` for Chinese word segmentation (no third-party
/// dependencies), combined with pre-computed IDF weights from `laws_vocab.json`.
/// This mirrors the Python jieba+IDF approach.
public final class LawStore: @unchecked Sendable {
    public init() {}
    // MARK: - Properties

    /// All searchable chunks loaded from the bundle.
    public private(set) var chunks: [LawChunk] = []

    /// Pre-computed IDF vocabulary: token → (document_frequency, idf_weight).
    private var vocabulary: [String: VocabEntry] = [:]

    /// Total document count (used for IDF normalization).
    private var docCount: Int = 0

    /// Chunks grouped by law ID for article-level lookup.
    private var chunksByLaw: [String: [LawChunk]] = [:]

    // MARK: - Types

    private struct VocabEntry: Codable {
        let df: Double
        let idf: Double
    }

    // MARK: - Loading

    /// Load all law data from the app bundle.
    ///
    /// - Parameter bundle: The bundle containing `LegalKnowledge/` resources.
    ///   Defaults to `.main`; tests should use `Bundle(for: type)` or
    ///   `Bundle.module`.
    public func load(from bundle: Bundle = .main) throws {
        let resourceURL: URL
        // Try subdirectory first, then root (XcodeGen flattens folder references)
        if let subdir = bundle.url(forResource: "LegalKnowledge", withExtension: nil) {
            resourceURL = subdir
        } else if bundle.url(forResource: "laws_chunks", withExtension: "json") != nil {
            resourceURL = bundle.bundleURL
        } else {
            throw LawStoreError.resourceNotFound("LegalKnowledge/ directory not found in bundle")
        }
        try loadChunks(from: resourceURL)
        try loadVocabulary(from: resourceURL)
    }

    private func loadChunks(from resourceURL: URL) throws {
        let chunksURL = resourceURL.appendingPathComponent("laws_chunks.json")
        let data = try Data(contentsOf: chunksURL)
        let decoder = JSONDecoder()
        chunks = try decoder.decode([LawChunk].self, from: data)

        // Build law-level index
        chunksByLaw = Dictionary(grouping: chunks, by: \.lawID)
        docCount = chunks.count
    }

    private func loadVocabulary(from resourceURL: URL) throws {
        let vocabURL = resourceURL.appendingPathComponent("laws_vocab.json")
        let data = try Data(contentsOf: vocabURL)
        let decoder = JSONDecoder()
        vocabulary = try decoder.decode([String: VocabEntry].self, from: data)
    }

    // MARK: - Public API

    /// Number of loaded chunks.
    public var chunkCount: Int { chunks.count }

    /// Get all chunks for a specific law.
    public func chunks(for lawID: String) -> [LawChunk] {
        chunksByLaw[lawID] ?? []
    }

    /// Get a specific article by law ID and article number.
    public func article(lawID: String, articleNum: String) -> LawChunk? {
        chunksByLaw[lawID]?.first { $0.articleNum == articleNum }
    }

    // MARK: - Keyword Search

    /// Search chunks by keyword relevance using Chinese word segmentation
    /// and pre-computed IDF weights.
    ///
    /// - Parameters:
    ///   - query: Natural language query in Chinese.
    ///   - limit: Maximum number of results to return (returns up to `limit * 5`
    ///     for RRF fusion).
    /// - Returns: Ranked list of (chunk, score) pairs.
    public func searchKeyword(_ query: String, limit: Int = 30) -> [LawSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Tokenize query using NLTokenizer
        let tokens = tokenize(trimmed)
        guard !tokens.isEmpty else { return [] }

        // Look up IDF weights for query tokens
        var queryWeights: [String: Double] = [:]
        for token in tokens {
            if let entry = vocabulary[token] {
                queryWeights[token] = entry.idf
            } else {
                // Unknown token: use a default high IDF (rare term)
                queryWeights[token] = max(0.1, Double(docCount) / 2.0)
            }
        }

        // Score every chunk
        var scored: [(chunk: LawChunk, score: Double)] = []
        scored.reserveCapacity(chunks.count)

        for chunk in chunks {
            let chunkTokens = tokenize(chunk.text)
            var score: Double = 0
            for token in tokens {
                if let weight = queryWeights[token] {
                    let tf = min(Double(chunkTokens.filter({ $0 == token }).count), 3.0)
                    score += weight * tf
                }
            }
            if score > 0 {
                // Normalize by document length to avoid long-doc bias
                var norm = score / (1.0 + sqrt(Double(chunkTokens.count)))
                // Category boost — down-weight guides and cases
                norm = applyCategoryBoost(chunk: chunk, score: norm)
                scored.append((chunk, norm))
            }
        }

        scored.sort { $0.score > $1.score }
        return scored
            .prefix(max(limit * 3, 100))
            .map { LawSearchResult(chunk: $0.chunk, score: Float($0.score)) }
    }

    // MARK: - Tokenization

    /// Tokenize Chinese text into words using `NLTokenizer`.
    ///
    /// Filters single-character tokens and common stop words to
    /// improve search relevance.
    func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = text

        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip single-char tokens (except digits)
            if token.count >= 2 || token.allSatisfy(\.isNumber) {
                // Skip stop words
                if !Self.stopWords.contains(token) {
                    tokens.append(token)
                }
            }
            return true
        }

        return tokens
    }

    // MARK: - Category Boosting

    /// Boost factors for different law categories.
    ///
    /// Guides, case collections, and administrative documents are down-weighted
    /// to prevent them from dominating search results over primary legislation.
    private static let categoryBoost: [String: Double] = [
        "民法典": 1.0, "刑法": 1.0, "社会法": 1.0,
        "经济法": 1.0, "司法解释": 1.0,
        "行政法": 0.9, "民法商法": 0.9, "宪法": 0.9,
        "宪法相关法": 0.9,
        "案例": 0.25, "办法": 0.25, "规定": 0.25, "其他": 0.25,
    ]

    private func applyCategoryBoost(chunk: LawChunk, score: Double) -> Double {
        let boost = Self.categoryBoost[chunk.category] ?? 0.8
        return score * boost
    }

    // MARK: - Stop Words

    /// Common interrogative and connective words filtered from search queries.
    private static let stopWords: Set<String> = [
        "怎么办", "怎样", "如何", "是否", "什么", "多少",
        "哪些", "哪个", "哪种", "怎么", "多久", "多长",
        "能不能", "可以吗", "行不行", "对不对",
        "导致", "造成", "致使", "引起", "产生", "形成",
        "根据", "按照", "依照", "关于", "对于", "有关",
        "及其", "以及", "或者", "并且", "因为", "所以",
        "的", "是", "在", "和", "与", "或", "之", "等",
    ]
}

// MARK: - Errors

public enum LawStoreError: Error {
    case resourceNotFound(String)
}
