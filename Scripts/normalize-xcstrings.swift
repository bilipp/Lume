#!/usr/bin/env swift
import Foundation

// Normalizes String Catalog (.xcstrings) files to Xcode's exact on-disk format.
//
// Xcode serializes catalogs with Foundation's JSONSerialization using pretty
// printing, sorted keys and unescaped slashes. Reproducing those exact options
// here is verified byte-for-byte identical to Xcode's output, so the committed
// file stays stable no matter what last wrote it (Xcode, xcstringstool, an
// editor, or an AI assistant) — and opening it in Xcode afterwards causes no
// churn.
//
// Usage: swift Scripts/normalize-xcstrings.swift <file.xcstrings> [<more>...]
// Exits non-zero (blocking the commit) if a file is not valid JSON.

let paths = Array(CommandLine.arguments.dropFirst())
var failed = false

for path in paths {
    let url = URL(fileURLWithPath: path)
    do {
        let original = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: original)
        let formatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if formatted != original {
            try formatted.write(to: url)
            print("normalized \(path)")
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
        failed = true
    }
}

exit(failed ? 1 : 0)
