import Foundation

// MARK: - EmbeddingProvider

/// Protocol for query-to-vector embedding models.
///
/// When an implementation is available (CoreML, MLX), it encodes a query
/// string into a normalized float32 vector compatible with the pre-computed
/// document embeddings.
///
/// Without a provider, the `LawIndex` falls back to keyword-only search.
public protocol EmbeddingProvider: Sendable {
    /// The dimension of embedding vectors produced by this provider.
    var dimension: Int { get }

    /// Encode a query string into a normalized embedding vector.
    ///
    /// The vector MUST be L2-normalized (unit length) for compatibility
    /// with the inner-product similarity used by `LawIndex`.
    func embed(_ text: String) async throws -> [Float]
}
