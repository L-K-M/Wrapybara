import Foundation

/// Reads and writes a `Codable` value as pretty-printed JSON, atomically.
///
/// Shared by the library document and the per-wrap runtime configurations. Two
/// choices are load-bearing:
///
/// - **Atomic writes.** These files are read by *other processes* — every running
///   site app watches its own configuration. A partial write would be parsed as
///   corruption by whoever read it mid-flight, so writes land via a temporary file
///   and a single `replaceItem` swap.
/// - **Sorted, pretty-printed keys.** The files are meant to be opened, read and
///   hand-edited; and stable key order means a two-line change is a two-line diff.
struct JSONFileStore {

    var fileManager: FileManager = .default

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Decodes the value at `url`, or `nil` when the file doesn't exist.
    /// Throws only when the file exists and can't be read or parsed.
    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(type, from: data)
    }

    /// Like `load`, but treats an unreadable file as absent. For the runtime's
    /// startup path, where a corrupt shared-store entry must not stop the app from
    /// falling back to its baked-in seed.
    func loadIfPossible<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        try? load(type, from: url)
    }

    /// Encodes `value` to `url`, creating the parent directory and replacing any
    /// existing file atomically.
    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try AppSupport.createDirectory(url.deletingLastPathComponent())
        let data = try Self.encoder.encode(value)

        // `Data.write(to:options:.atomic)` is atomic within a volume, which is all
        // that's needed here — both paths are under Application Support.
        try data.write(to: url, options: [.atomic])
    }

    /// Removes the file at `url` if it's there. Missing is success.
    func remove(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
