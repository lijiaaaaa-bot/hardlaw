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
        XCTAssertTrue(tokens.contains("劳动合同"))
    }

    func testStopWordFiltering() async throws {
        let store = LawStore()
        try store.load(from: testBundle())
        let tokens = store.tokenize("拖欠工资怎么办")
        XCTAssertTrue(!tokens.contains("怎么办"))
        XCTAssertTrue(tokens.contains("拖欠工资"))
    }
}

private func testBundle() -> Bundle {
    // Resources copied to main app bundle by XcodeGen
    return Bundle.main
}
