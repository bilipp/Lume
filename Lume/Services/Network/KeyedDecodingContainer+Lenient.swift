import Foundation

// MARK: - Lenient field decoding

/// Xtream panel forks disagree on JSON types field by field — the same key can
/// arrive as a string on one provider and a number on the next. These helpers
/// accept either representation (and swallow null / absent keys) so a single
/// odd field can't fail a whole response.
nonisolated extension KeyedDecodingContainer {
    func lenientString(forKey key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return String(double) }
        return nil
    }

    func lenientInt(forKey key: Key) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Int(string) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return Int(double) }
        return nil
    }

    func lenientDouble(forKey key: Key) -> Double? {
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return double }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Double(string) }
        return nil
    }
}
