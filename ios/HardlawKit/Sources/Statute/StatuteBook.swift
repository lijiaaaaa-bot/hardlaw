import Foundation

// MARK: - StatuteBook

/// A collection of statutes — the "legal code" for a domain.
/// Provides lookup, validation, and serialization for multiple statutes.
/// Mirrors Python `hardlaw.statute.StatuteBook`.
public struct StatuteBook: Codable, Sendable {
    /// Statutes keyed by name.
    private var statutes: [String: Statute] = [:]

    public init(statutes: [Statute] = []) {
        for s in statutes {
            add(s)
        }
    }

    /// Add a statute to the book. Replaces if name already exists.
    public mutating func add(_ statute: Statute) {
        statutes[statute.name] = statute
    }

    /// Look up a statute by name.
    public func get(_ name: String) -> Statute? {
        statutes[name]
    }

    /// Look up multiple statutes. Silently skips unknown names.
    /// Mirrors Python `StatuteBook.get_all`.
    public func getAll(_ names: [String]) -> [Statute] {
        names.compactMap { statutes[$0] }
    }

    /// Return all statute names (in insertion order).
    public func listNames() -> [String] {
        Array(statutes.keys)
    }

    public var count: Int { statutes.count }

    public func contains(_ name: String) -> Bool {
        statutes[name] != nil
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case statutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let statuteList = try container.decodeIfPresent([Statute].self, forKey: .statutes) ?? []
        for s in statuteList {
            statutes[s.name] = s
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Array(statutes.values), forKey: .statutes)
    }

    /// Serialize all statutes (mirrors Python `to_dict`).
    public func toDict() -> [String: Any] {
        ["statutes": Array(statutes.values).map { $0.toDict() }]
    }

    /// Deserialize a statute book (mirrors Python `from_dict`).
    public static func fromDict(_ data: [String: Any]) -> StatuteBook {
        let statutes = (data["statutes"] as? [[String: Any]] ?? []).map { Statute.fromDict($0) }
        return StatuteBook(statutes: statutes)
    }
}
