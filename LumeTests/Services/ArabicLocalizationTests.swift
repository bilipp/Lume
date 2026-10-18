//
//  ArabicLocalizationTests.swift
//  LumeTests
//
//  Arabic was added as a whole-catalog translation rather than key by key, so
//  it is asserted catalog-wide: it keeps pace with German, and every Arabic
//  value formats with the arguments the source passes.
//

import Foundation
@testable import Lume
import Testing

@Suite("Arabic localization")
struct ArabicLocalizationTests {
    /// One printf argument: its explicit `n$` position, if any, the conversion
    /// with that position stripped (`%lld`, `%@`), and whether it is glued to
    /// a word — an English plural suffix (`movie%@`) that Arabic drops.
    private struct Specifier {
        let position: Int?
        let conversion: String
        let isWordSuffix: Bool
    }

    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaA%])"#
    )

    private static func specifiers(in text: String) -> [Specifier] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let kind = Range(match.range(at: 2), in: text),
                  text[kind] != "%"
            else { return nil }
            let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
            let conversion = String(text[whole]).replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression)
            let glued = whole.lowerBound > text.startIndex && text[text.index(before: whole.lowerBound)].isLetter
            return Specifier(position: position, conversion: conversion, isWordSuffix: glued && conversion == "%@")
        }
    }

    @Test func `every key German translates is translated in Arabic`() throws {
        let catalog = try StringCatalog.localizable()
        let missing = catalog.keys.filter { key in
            let languages = catalog.translatedLanguages(for: key) ?? []
            return languages.contains("de") && !languages.contains("ar")
        }
        #expect(missing.isEmpty, "untranslated in Arabic: \(missing.sorted())")
    }

    @Test func `every Arabic value formats with the source's arguments`() throws {
        let catalog = try StringCatalog.localizable()
        for key in catalog.keys {
            guard let arabic = catalog.localizations(for: key)?["ar"] else { continue }
            let source = Self.specifiers(in: catalog.sourceValue(for: key))
            let required = source.filter { !$0.isWordSuffix }.map(\.conversion)
            let translated = Self.specifiers(in: arabic)

            guard translated.contains(where: { $0.position != nil }) else {
                let conversions = translated.map(\.conversion)
                #expect(
                    conversions == source.map(\.conversion) || conversions == required,
                    "\(key): \(conversions) do not match the source's arguments"
                )
                continue
            }
            for specifier in translated {
                let index = (specifier.position ?? 0) - 1
                #expect(
                    source.indices.contains(index) && source[index].conversion == specifier.conversion,
                    "\(key): \(specifier.conversion) at position \(index + 1) does not match the source"
                )
            }
            let used = Set(translated.compactMap(\.position))
            let dropped = source.indices.filter { !used.contains($0 + 1) && !source[$0].isWordSuffix }
            #expect(dropped.isEmpty, "\(key): drops source arguments at \(dropped.map { $0 + 1 })")
        }
    }

    @Test func `every shipping locale is declared in Info.plist`() throws {
        let url = repoRootURL().appendingPathComponent("Lume/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let declared = try #require((plist as? [String: Any])?["CFBundleLocalizations"] as? [String])
        #expect(shippingLocales.isSubset(of: Set(declared)))
    }
}
