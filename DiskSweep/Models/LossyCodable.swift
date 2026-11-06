import Foundation

/// Decodes one element of a collection, turning a failure into `nil` so one bad element
/// doesn't discard the rest. Used for cleanup history entries.
struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Cleanup locations are stored by raw value. A value this build doesn't know, from a newer
/// build or a removed category, is dropped instead of failing the whole decode. Encoding is
/// unchanged, so the stored format stays the same.
extension KeyedDecodingContainer {
    func decodeLossyLocations(forKey key: Key) throws -> [CleanupLocation] {
        try decode([String].self, forKey: key).compactMap(CleanupLocation.init(rawValue:))
    }

    func decodeLossyLocationSet(forKey key: Key) throws -> Set<CleanupLocation> {
        Set(try decodeLossyLocations(forKey: key))
    }
}
