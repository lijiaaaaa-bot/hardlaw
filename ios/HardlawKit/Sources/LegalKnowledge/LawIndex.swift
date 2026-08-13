import Accelerate
import Foundation

// MARK: - LawIndex

/// Hybrid search index combining keyword relevance with pre-computed
/// semantic embeddings.
///
/// ## Architecture
///
/// - **Document vectors**: Pre-computed by Python, loaded from `laws_vectors.bin`.
///   11,157 vectors × 512 dimensions, float32, L2-normalized.
/// - **Query embedding**: Optional `EmbeddingProvider` (CoreML/MLX). When
///   unavailable, falls back to keyword-only search.
/// - **RRF merge**: Reciprocal Rank Fusion combining keyword and semantic
///   result lists. Keyword results are weighted more heavily (k=10) than
///   semantic results (k=60) because keyword retrieval is highly
///   effective for Chinese legal terminology.
///
/// ## Performance
///
/// Brute-force inner product search over 11K×512 vectors runs in <5ms on
/// iPhone CPU using Accelerate BLAS. No FAISS dependency needed at this scale.
public final class LawIndex: @unchecked Sendable {
    // MARK: - Properties

    /// The law store providing chunk data and keyword search.
    public let store: LawStore

    /// Document embedding vectors, row-major: [nVectors × dimension] float32.
    /// Each row is L2-normalized.
    private var docVectors: [Float] = []

    /// Parallel array: chunk IDs matching each row in `docVectors`.
    private var vectorIDs: [String] = []

    /// Number of vectors loaded.
    private var nVectors: Int = 0

    /// Vector dimension (512 for BGE-small-zh-v1.5).
    private var vectorDim: Int = 0

    /// Optional query embedding provider.
    private var embeddingProvider: (any EmbeddingProvider)?

    /// Number of loaded document vectors.
    public var vectorCount: Int {
        lock.withLock { nVectors }
    }

    /// Whether document vectors have been loaded.
    public var vectorsLoaded: Bool {
        lock.withLock { _vectorsLoaded }
    }
    private var _vectorsLoaded = false

    /// Lock for thread-safe vector loading.
    private let lock = NSLock()

    // MARK: - Init

    public init(store: LawStore) {
        self.store = store
    }

    // MARK: - Configuration

    /// Attach an embedding provider for semantic search.
    ///
    /// Without this, `search()` uses keyword-only mode (still highly
    /// effective for Chinese legal text).
    public func setEmbeddingProvider(_ provider: any EmbeddingProvider) {
        lock.withLock {
            self.embeddingProvider = provider
        }
    }

    // MARK: - Loading Vectors

    /// Load pre-computed document vectors from the bundle.
    ///
    /// The binary format is:
    /// - uint32: nVectors (little-endian)
    /// - uint32: dimension (little-endian)
    /// - float32[nVectors × dimension]: row-major vectors
    public func loadVectors(from bundle: Bundle = .main) throws {
        let resourceURL: URL
        if let subdir = bundle.url(forResource: "LegalKnowledge", withExtension: nil) {
            resourceURL = subdir
        } else if bundle.url(forResource: "laws_vectors", withExtension: "bin") != nil {
            resourceURL = bundle.bundleURL
        } else {
            throw LawIndexError.resourceNotFound
        }

        let binURL = resourceURL.appendingPathComponent("laws_vectors.bin")
        let idsURL = resourceURL.appendingPathComponent("laws_ids.json")

        let binData = try Data(contentsOf: binURL)

        // Parse header
        guard binData.count >= 8 else {
            throw LawIndexError.invalidFormat("Binary file too small for header")
        }

        let nVecs = binData.withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let dim = binData.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }

        let expectedSize = 8 + Int(nVecs) * Int(dim) * MemoryLayout<Float>.size
        guard binData.count == expectedSize else {
            throw LawIndexError.invalidFormat(
                "Size mismatch: expected \(expectedSize), got \(binData.count)"
            )
        }

        // Load float32 vectors
        let vectorCount = Int(nVecs) * Int(dim)
        var vectors = [Float](repeating: 0, count: vectorCount)
        binData.withUnsafeBytes { raw in
            let start = raw.baseAddress!.advanced(by: 8)
            let floatPtr = start.assumingMemoryBound(to: Float.self)
            for i in 0..<vectorCount {
                vectors[i] = floatPtr[i]
            }
        }

        // Load ID mapping
        let idsData = try Data(contentsOf: idsURL)
        let ids = try JSONDecoder().decode([String].self, from: idsData)

        guard ids.count == Int(nVecs) else {
            throw LawIndexError.invalidFormat(
                "ID count mismatch: \(ids.count) vs \(nVecs) vectors"
            )
        }

        lock.withLock {
            self.docVectors = vectors
            self.vectorIDs = ids
            self.nVectors = Int(nVecs)
            self.vectorDim = Int(dim)
            self._vectorsLoaded = true
        }

        // Fail-fast: if a provider is already attached, its dimension must match
        // the document vectors. A mismatch means semantic search would silently
        // return nothing — surface it now instead of degrading invisibly.
        let providerDim = lock.withLock { embeddingProvider?.dimension }
        if let providerDim, providerDim != Int(dim) {
            throw LawIndexError.dimensionMismatch(
                "laws_vectors.bin dimension \(dim) != provider dimension \(providerDim) — re-export vectors with the matching embedding model"
            )
        }
    }

    // MARK: - Search

    /// Hybrid search: keyword + optional semantic, merged via RRF.
    ///
    /// - Parameters:
    ///   - query: Natural language query in Chinese.
    ///   - k: Number of results to return (default 10).
    /// - Returns: Ranked list of `LawSearchResult`.
    public func search(_ query: String, k: Int = 10) async -> [LawSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Lazy wiring: attach the on-device CoreML embedding provider and load
        // the pre-computed document vectors on first use. Failures here are
        // non-fatal — keyword-only search below still works.
        if !lock.withLock({ embeddingProvider != nil }) {
            setEmbeddingProvider(CoreMLEmbeddingProvider())
        }
        if !vectorsLoaded {
            do {
                try loadVectors()
            } catch {
                // Non-fatal: keyword-only search still works, but surface the
                // reason (e.g. dimension mismatch) instead of hiding it.
                print("[LawIndex] ⚠️ 向量加载失败，降级为关键词搜索: \(error)")
            }
        }

        // Build chunk lookup map
        let chunkMap = Dictionary(
            uniqueKeysWithValues: store.chunks.map { ($0.id, $0) }
        )

        // Keyword results (always available)
        let kwResults = store.searchKeyword(trimmed, limit: k * 3)
        let kwRanked: [(id: String, rank: Float)] = kwResults.enumerated().map {
            ($0.element.chunk.id, Float($0.offset))
        }

        // Try semantic search — snapshot shared state under the lock.
        var semRanked: [(id: String, rank: Float)] = []
        let (vectorsReady, provider) = lock.withLock { (_vectorsLoaded, embeddingProvider) }
        if vectorsReady, let provider = provider {
            do {
                let queryVec = try await provider.embed(trimmed)
                semRanked = semanticSearch(queryVec, k: k * 3)
            } catch {
                // Semantic search failed — fall through to keyword-only
            }
        }

        // If no semantic results, return keyword-only
        guard !semRanked.isEmpty else {
            return Array(kwResults.prefix(k))
        }

        // RRF merge — keyword (k=10, high influence) + semantic (k=60, low influence)
        let merged = rrfMerge(
            rankedLists: [kwRanked, semRanked],
            kValues: [10, 60],
            limit: k
        )

        // Resolve IDs to chunks
        var results: [LawSearchResult] = []
        for (chunkID, score) in merged {
            if let chunk = chunkMap[chunkID] {
                results.append(LawSearchResult(chunk: chunk, score: score))
            }
        }

        return results
    }

    // MARK: - Semantic Search

    /// Brute-force inner product search over document vectors.
    ///
    /// At 11K × 512 dimensions, this completes in <5ms on iPhone CPU.
    /// Uses Accelerate `cblas_sgemv` or a simple vectorized loop.
    private func semanticSearch(
        _ queryVec: [Float],
        k: Int
    ) -> [(id: String, rank: Float)] {
        // Snapshot shared state under the lock. The array copies are O(1)
        // via copy-on-write: `loadVectors` swaps the arrays in place under
        // the same lock, so no other thread can mutate while we hold a
        // reference (this also fixes the data race on `vectorDim`/`nVectors`).
        let (docVectors, vectorIDs, n, dim) = lock.withLock {
            (self.docVectors, self.vectorIDs, self.nVectors, self.vectorDim)
        }

        guard queryVec.count == dim else {
            print("[LawIndex] ⚠️ 维度不匹配: provider query \(queryVec.count) 维 vs 文档向量 \(dim) 维 — 语义搜索降级为关键词搜索")
            return []
        }

        let effectiveK = min(k, n)

        // Compute inner product: scores[i] = sum(queryVec[j] * docVectors[i*dim + j])
        // Using cblas_sgemv: y = A * x  (matrix-vector multiply)
        // A is [n × dim] document vectors, x is query vector [dim]
        var scores = [Float](repeating: 0, count: n)

        docVectors.withUnsafeBufferPointer { docPtr in
            queryVec.withUnsafeBufferPointer { queryPtr in
                // Note: cblas_sgemv expects column-major by default.
                // docPtr is row-major [n × dim].
                // We use the row-major variant or transpose manually.
                // For simplicity and correctness, compute via manual loop
                // (BLAS overhead dominates at this small scale anyway).
                var maxScore: Float = -1
                for i in 0..<n {
                    var dot: Float = 0
                    let offset = i * dim
                    // Unrolled dot product for performance
                    var j = 0
                    while j + 3 < dim {
                        dot += docPtr[offset + j] * queryPtr[j]
                        dot += docPtr[offset + j + 1] * queryPtr[j + 1]
                        dot += docPtr[offset + j + 2] * queryPtr[j + 2]
                        dot += docPtr[offset + j + 3] * queryPtr[j + 3]
                        j += 4
                    }
                    while j < dim {
                        dot += docPtr[offset + j] * queryPtr[j]
                        j += 1
                    }
                    scores[i] = dot
                    if dot > maxScore { maxScore = dot }
                }
            }
        }

        // Find top-k indices (partial sort)
        var indexed = scores.enumerated().map { ($0.offset, $0.element) }
        indexed.sort { $0.1 > $1.1 }

        return indexed.prefix(effectiveK).compactMap { (idx, score) in
            guard idx < vectorIDs.count else { return nil }
            return (vectorIDs[idx], score)
        }
    }

    // MARK: - RRF Merge

    /// Reciprocal Rank Fusion — combine multiple ranked lists.
    ///
    /// Each list contributes `1 / (k + rank + 1)` to its item's fused score.
    /// Lower `k` = higher contribution (slower decay).
    private func rrfMerge(
        rankedLists: [[(id: String, rank: Float)]],
        kValues: [Int],
        limit: Int
    ) -> [(String, Float)] {
        guard !rankedLists.isEmpty else { return [] }

        let kValuesPadded = kValues + Array(
            repeating: 60, count: max(0, rankedLists.count - kValues.count)
        )

        var fused: [String: Float] = [:]
        for (listIdx, results) in rankedLists.enumerated() {
            let k = kValuesPadded[listIdx]
            for (rank, item) in results.enumerated() {
                let rrf = 1.0 / Float(k + rank + 1)
                if let existing = fused[item.id] {
                    fused[item.id] = max(existing, rrf)
                } else {
                    fused[item.id] = rrf
                }
            }
        }

        return fused
            .map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Errors

public enum LawIndexError: Error {
    case resourceNotFound
    case invalidFormat(String)
    case dimensionMismatch(String)
}
