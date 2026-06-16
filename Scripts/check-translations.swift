#!/usr/bin/env swift
import Foundation

// Checks String Catalog (.xcstrings) files for missing or untranslated strings.
//
// Exits non-zero if any language is missing translations, so it can be wired
// into CI or a pre-commit hook.
//
// Usage:
//   swift Scripts/check-translations.swift                         # checks Lume/Localizable.xcstrings
//   swift Scripts/check-translations.swift path/to/File.xcstrings  # explicit file(s)

let paths: [String] = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["Lume/Localizable.xcstrings"]

var failed = false

for path in paths {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = root["strings"] as? [String: Any],
          let sourceLanguage = root["sourceLanguage"] as? String
    else {
        fputs("error: \(path): could not parse as .xcstrings JSON\n", stderr)
        failed = true
        continue
    }

    // Collect all languages present in the file
    var allLanguages = Set<String>()
    for (_, value) in strings {
        guard let entry = value as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any]
        else { continue }
        allLanguages.formUnion(localizations.keys)
    }
    allLanguages.remove(sourceLanguage)

    var missingByLanguage: [String: [String]] = [:]
    var newStateByLanguage: [String: [String]] = [:]

    for (key, value) in strings {
        guard let entry = value as? [String: Any] else { continue }
        let localizations = entry["localizations"] as? [String: Any] ?? [:]

        for language in allLanguages {
            guard let locEntry = localizations[language] as? [String: Any],
                  let stringUnit = locEntry["stringUnit"] as? [String: Any],
                  let value = stringUnit["value"] as? String, !value.isEmpty
            else {
                missingByLanguage[language, default: []].append(key)
                continue
            }
            let state = stringUnit["state"] as? String ?? ""
            if state == "new" || state == "needs_review" {
                newStateByLanguage[language, default: []].append(key)
            }
        }
    }

    var fileHadIssues = false

    for language in allLanguages.sorted() {
        let missing = missingByLanguage[language]?.sorted() ?? []
        let needsReview = newStateByLanguage[language]?.sorted() ?? []

        if !missing.isEmpty {
            print("\n\(path) [\(language)] — \(missing.count) missing translation(s):")
            for key in missing {
                print("  \(key)")
            }
            fileHadIssues = true
            failed = true
        }

        if !needsReview.isEmpty {
            print("\n\(path) [\(language)] — \(needsReview.count) string(s) marked 'new' or 'needs_review':")
            for key in needsReview {
                print("  \(key)")
            }
        }
    }

    if !fileHadIssues {
        let reviewCount = newStateByLanguage.values.flatMap(\.self).count
        if reviewCount > 0 {
            print("\(path): OK (no missing translations; \(reviewCount) marked for review)")
        } else {
            print("\(path): OK")
        }
    }
}

exit(failed ? 1 : 0)
