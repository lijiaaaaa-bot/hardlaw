import Testing
import Foundation
@testable import HardlawKit

// MARK: - LegalKnowledge Tests

/// Tests for the local law search module.
///
/// These tests verify that the exported data loads correctly and that
/// keyword search returns relevant results for common Chinese legal queries.
///
/// Prerequisites:
///   - `scripts/export_for_ios.py` has been run to generate the bundle resources
///   - Tests use `Bundle.module` or a test bundle containing `LegalKnowledge/`
@Suite struct LegalKnowledgeTests {

    // MARK: - LawStore Tests

    @Suite struct LawStoreTests {
        @Test func loadFromBundle() async throws {
            let store = LawStore()
            // In test environment, data is in the test bundle
            try store.load(from: testBundle())

            #expect(store.chunkCount > 10_000)
        }

        @Test func keywordSearchLaborLaw() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let results = store.searchKeyword("加班费计算标准", limit: 10)
            #expect(!results.isEmpty)

            // Should find 劳动法 or 劳动合同法 articles about overtime pay
            let hasRelevant = results.contains { result in
                result.chunk.text.contains("加班费")
                || result.chunk.text.contains("延长工作时间")
            }
            #expect(hasRelevant)
        }

        @Test func keywordSearchProbation() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let results = store.searchKeyword("试用期最长多久", limit: 5)

            // Top result should be about probation period limits
            let topChunk = try #require(results.first?.chunk)
            #expect(topChunk.text.contains("试用期"))
        }

        @Test func keywordSearchMaternityLeave() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let results = store.searchKeyword("女职工产假多少天", limit: 5)

            let topChunk = try #require(results.first?.chunk)
            #expect(topChunk.text.contains("产假") || topChunk.text.contains("女职工"))
        }

        @Test func chunkLookupByLaw() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let laborLawChunks = store.chunks(for: "劳动法")
            #expect(!laborLawChunks.isEmpty)
            #expect(laborLawChunks.count >= 100)
        }
    }

    // MARK: - LawIndex Tests

    @Suite struct LawIndexTests {
        @Test func loadVectors() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let index = LawIndex(store: store)
            try index.loadVectors(from: testBundle())

            // Verify vectors loaded correctly
            #expect(index.vectorCount > 10_000)
        }

        @Test func keywordOnlySearch() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let index = LawIndex(store: store)
            // Don't load vectors — should fall back to keyword-only
            let results = await index.search("未签劳动合同的双倍工资", k: 5)

            #expect(!results.isEmpty)
            // Should find 劳动合同法第八十二条
            let foundArticle = results.contains { result in
                result.chunk.lawID == "劳动合同法"
                && result.chunk.articleNum.contains("八十二")
            }
            #expect(foundArticle)
        }

        @Test func unliteralDismissalSearch() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let index = LawIndex(store: store)
            let results = await index.search("用人单位单方解除劳动合同", k: 5)

            #expect(!results.isEmpty)
            let topChunk = try #require(results.first?.chunk)
            // Should be about 劳动合同法第四十三条 or similar
            #expect(
                topChunk.lawID.contains("劳动合同法")
                || topChunk.lawID.contains("劳动法")
            )
        }
    }

    // MARK: - Tokenization Tests

    @Suite struct TokenizationTests {
        @Test func chineseWordSegmentation() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            // Access tokenizer through a known method
            let tokens = store.tokenize("未签劳动合同的双倍工资")
            #expect(!tokens.isEmpty)
            // Should contain meaningful tokens
            #expect(tokens.contains("劳动合同"))
        }

        @Test func stopWordFiltering() async throws {
            let store = LawStore()
            try store.load(from: testBundle())

            let tokens = store.tokenize("拖欠工资怎么办")
            // "怎么办" should be filtered
            #expect(!tokens.contains("怎么办"))
            // "拖欠工资" should be preserved
            #expect(tokens.contains("拖欠工资"))
        }
    }
}

// MARK: - Test Helpers

/// Locate the test bundle containing LegalKnowledge resources.
private func testBundle() -> Bundle {
    // Try to find the bundle containing our test resources.
    // In an XcodeGen-generated project, resources land in the main bundle
    // or the test host bundle.

    // First try: Bundle.module (SwiftPM style)
    #if SWIFT_PACKAGE
    return Bundle.module
    #endif

    // Second try: the bundle containing this test class
    let thisBundle = Bundle(for: LegalKnowledgeTestsAnchor.self)

    // Third try: the main bundle
    if Bundle.main.url(forResource: "LegalKnowledge", withExtension: nil) != nil {
        return Bundle.main
    }

    return thisBundle
}

/// Anchor class for locating the test bundle.
private final class LegalKnowledgeTestsAnchor: NSObject {}
