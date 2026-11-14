import Foundation

/// A named, reusable report definition, so the same multi-section report (e.g. for a recurring
/// clinic visit) can be regenerated without re-picking every section.
public struct ReportPreset: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var definition: ReportDefinition
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, definition: ReportDefinition, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.definition = definition
        self.createdAt = createdAt
    }
}

/// Persistence for presets. Hosts can back this with their own storage (Trio's `FileStorage`,
/// LoopFollow's `Storage`) or use `JSONFileReportPresetStore`.
public protocol ReportPresetStore {
    func load() throws -> [ReportPreset]
    func save(_ presets: [ReportPreset]) throws
}

extension ReportPresetStore {
    /// Most recently created first.
    public func presets() throws -> [ReportPreset] {
        try load().sorted { $0.createdAt > $1.createdAt }
    }

    /// Inserts, or replaces the preset with the same id.
    public func upsert(_ preset: ReportPreset) throws {
        var presets = try load()
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        try save(presets)
    }

    public func delete(id: UUID) throws {
        var presets = try load()
        presets.removeAll { $0.id == id }
        try save(presets)
    }
}

public struct JSONFileReportPresetStore: ReportPresetStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> [ReportPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ReportPreset].self, from: Data(contentsOf: url))
    }

    public func save(_ presets: [ReportPreset]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(presets).write(to: url, options: .atomic)
    }
}
