import XCTest
import Foundation
@testable import HardlawKit

final class LegalKnowledgeTests: XCTestCase {

    // MARK: - LawStore

    func testLoadFromBundle() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        XCTAssertTrue(store.chunkCount > 10_000)
    }

    func testKeywordSearchLaborLaw() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let results = store.searchKeyword("加班费计算标准", limit: 10)
        XCTAssertTrue(!results.isEmpty)
        let hasRelevant = results.contains { $0.chunk.text.contains("加班费") || $0.chunk.text.contains("延长工作时间") }
        XCTAssertTrue(hasRelevant)
    }

    func testKeywordSearchProbation() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let results = store.searchKeyword("试用期最长多久", limit: 5)
        let topChunk = try XCTUnwrap(results.first?.chunk)
        XCTAssertTrue(topChunk.text.contains("试用期"))
    }

    func testKeywordSearchMaternityLeave() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let results = store.searchKeyword("女职工产假多少天", limit: 5)
        let topChunk = try XCTUnwrap(results.first?.chunk)
        XCTAssertTrue(topChunk.text.contains("产假") || topChunk.text.contains("女职工"))
    }

    func testChunkLookupByLaw() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let chunks = store.chunks(for: "劳动法")
        XCTAssertTrue(!chunks.isEmpty)
        XCTAssertTrue(chunks.count >= 100)
    }

    // MARK: - LawIndex

    func testLoadVectors() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let index = LawIndex(store: store)
        try index.loadVectors(from: testBundle())
        XCTAssertTrue(index.vectorCount > 10_000)
    }

    func testKeywordOnlySearch() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let index = LawIndex(store: store)
        let results = await index.search("未签劳动合同的双倍工资", k: 5)
        XCTAssertTrue(!results.isEmpty)
        let foundArticle = results.contains { $0.chunk.lawID == "劳动合同法" && $0.chunk.articleNum.contains("八十二") }
        XCTAssertTrue(foundArticle)
    }

    func testUnliteralDismissalSearch() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let index = LawIndex(store: store)
        let results = await index.search("用人单位单方解除劳动合同", k: 5)
        XCTAssertTrue(!results.isEmpty)
        let topChunk = try XCTUnwrap(results.first?.chunk)
        XCTAssertTrue(topChunk.lawID.contains("劳动合同法") || topChunk.lawID.contains("劳动法"))
    }

    // MARK: - Tokenization

    func testChineseWordSegmentation() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let tokens = store.tokenize("未签劳动合同的双倍工资")
        XCTAssertTrue(!tokens.isEmpty)
        // NLTokenizer segments 劳动合同 as the words 劳动 + 合同
        XCTAssertTrue(tokens.contains("劳动"))
        XCTAssertTrue(tokens.contains("合同"))
        // Single-character tokens (未/签/的/双/倍) are filtered out
        XCTAssertTrue(!tokens.contains("的"))
    }

    func testStopWordFiltering() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let tokens = store.tokenize("拖欠工资怎么办")
        XCTAssertTrue(!tokens.contains("怎么办"))
        // NLTokenizer segments 拖欠工资 as the words 拖欠 + 工资
        XCTAssertTrue(tokens.contains("拖欠"))
        XCTAssertTrue(tokens.contains("工资"))
    }

    // MARK: - Semantic Search

    /// A query composed of Private-Use-Area characters that appear in no law
    /// chunk. NLTokenizer emits exactly one kept token, and no chunk contains
    /// it — the keyword path provably returns zero results, so tests exercise
    /// the semantic path in isolation.
    private let keywordMissQuery = String(repeating: "\u{E000}", count: 4)

    func testSemanticSearchContributesResultsWhenKeywordMisses() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let (firstID, firstVector) = try firstDocumentVector(from: testBundle())
        let index = LawIndex(store: store)
        try index.loadVectors(from: testBundle())
        index.setEmbeddingProvider(
            StubEmbeddingProvider(dimension: firstVector.count, vector: firstVector)
        )

        // The keyword path finds nothing for this query, so only the semantic
        // path can produce results. The stub returns the exact first document
        // vector, which must rank as the top semantic hit.
        let results = await index.search(keywordMissQuery, k: 5)
        XCTAssertFalse(results.isEmpty, "semantic path should return results")
        XCTAssertTrue(
            results.contains { $0.chunk.id == firstID },
            "exact vector match should appear in semantic results"
        )
    }

    func testSemanticSearchExactMatchRanksFirst() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let (firstID, firstVector) = try firstDocumentVector(from: testBundle())
        let index = LawIndex(store: store)
        try index.loadVectors(from: testBundle())
        index.setEmbeddingProvider(
            StubEmbeddingProvider(dimension: firstVector.count, vector: firstVector)
        )

        // With the query embedding exactly equal to the first document
        // vector (L2-normalized, inner product = 1.0), the semantic list
        // ranks that document first — verify RRF preserves it.
        let semanticOnly = await index.search(keywordMissQuery, k: 1)
        XCTAssertEqual(semanticOnly.first?.chunk.id, firstID)
    }

    func testSearchWiresProviderAndVectorsLazily() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let index = LawIndex(store: store)

        // search() must self-attach the CoreML embedding provider and load
        // the pre-computed document vectors on first use.
        let results = await index.search("加班费计算标准", k: 3)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(index.vectorsLoaded)
        XCTAssertTrue(index.vectorCount > 10_000)
        // Keyword relevance is preserved when the provider cannot embed
        // (BGE-small-zh.mlmodelc is not shipped in this repo).
        let topChunk = try XCTUnwrap(results.first?.chunk)
        XCTAssertTrue(topChunk.text.contains("加班费") || topChunk.text.contains("延长工作时间"))
    }

    // MARK: - CoreMLEmbeddingProvider

    func testCoreMLEmbeddingProviderDimension() {
        let provider = CoreMLEmbeddingProvider()
        XCTAssertEqual(provider.dimension, 512)
    }

    func testCoreMLEmbeddingProviderFailsGracefullyWithoutModel() async throws {
        let provider = CoreMLEmbeddingProvider()
        do {
            _ = try await provider.embed("劳动合同解除")
            XCTFail("embed() should throw: BGE-small-zh.mlmodelc is not bundled")
        } catch CoreMLEmbeddingProvider.LoadError.modelNotFound {
            // Expected — the model asset ships with the app bundle, not the repo.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private struct StubEmbeddingProvider: EmbeddingProvider {
    let dimension: Int
    let vector: [Float]

    func embed(_ text: String) async throws -> [Float] {
        vector
    }
}

/// Read the first document vector (id + float32 row) from the bundled
/// `laws_vectors.bin` so tests can hand it back as a stub query embedding.
private func firstDocumentVector(from bundle: Bundle) throws -> (id: String, vector: [Float]) {
    let resourceURL: URL
    if let subdir = bundle.url(forResource: "LegalKnowledge", withExtension: nil) {
        resourceURL = subdir
    } else {
        resourceURL = bundle.bundleURL
    }

    let binData = try Data(contentsOf: resourceURL.appendingPathComponent("laws_vectors.bin"))
    let nVecs = binData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let dim = binData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    precondition(nVecs > 0, "laws_vectors.bin must contain at least one vector")

    var vector = [Float](repeating: 0, count: Int(dim))
    binData.withUnsafeBytes { raw in
        let floats = raw.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Float.self)
        for i in 0..<Int(dim) {
            vector[i] = floats[i]
        }
    }

    let idsData = try Data(contentsOf: resourceURL.appendingPathComponent("laws_ids.json"))
    let ids = try JSONDecoder().decode([String].self, from: idsData)
    return (ids[0], vector)
}

private func testBundle() -> Bundle {
    // Resources copied to main app bundle by XcodeGen
    return Bundle.main
}
