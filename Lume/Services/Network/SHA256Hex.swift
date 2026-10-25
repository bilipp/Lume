//
//  SHA256Hex.swift
//  Lume
//

import CryptoKit
import Foundation

/// Lowercase hex SHA-256 of the string's UTF-8 bytes.
nonisolated func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}
