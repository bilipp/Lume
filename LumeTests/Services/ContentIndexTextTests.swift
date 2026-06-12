import Foundation
@testable import Lume
import Testing

struct ContentIndexTextTests {
    // MARK: - searchQuery

    @Test func `plain title passes through`() {
        let query = ContentIndexText.searchQuery(for: "Inception")
        #expect(query.title == "Inception")
        #expect(query.year == nil)
    }

    @Test func `parenthesized year is extracted`() {
        let query = ContentIndexText.searchQuery(for: "Der Pate (1972)")
        #expect(query.title == "Der Pate")
        #expect(query.year == 1972)
    }

    @Test func `country prefix and quality suffix are stripped`() {
        let query = ContentIndexText.searchQuery(for: "DE | Der Pate (1972) 4K")
        #expect(query.title == "Der Pate")
        #expect(query.year == 1972)
    }

    @Test func `bracketed tags and bare year are stripped`() {
        let query = ContentIndexText.searchQuery(for: "[MULTI] Inception 2010 FHD")
        #expect(query.title == "Inception")
        #expect(query.year == 2010)
    }

    @Test func `quality tokens are removed case-insensitively`() {
        let query = ContentIndexText.searchQuery(for: "Oppenheimer 2160p HEVC hdr")
        #expect(query.title == "Oppenheimer")
        #expect(query.year == nil)
    }

    @Test func `stacked prefixes are stripped`() {
        let query = ContentIndexText.searchQuery(for: "4K: EN | Dune Part Two")
        #expect(query.title == "Dune Part Two")
        #expect(query.year == nil)
    }

    @Test func `title that is only a year is preserved`() {
        let query = ContentIndexText.searchQuery(for: "2012")
        #expect(query.title == "2012")
        #expect(query.year == nil)
    }

    @Test func `last year wins when a year leads the title`() {
        let query = ContentIndexText.searchQuery(for: "2012 (2009)")
        #expect(query.title == "2012")
        #expect(query.year == 2009)
    }

    @Test func `lowercase title before dash is not treated as a tag`() {
        let query = ContentIndexText.searchQuery(for: "Up - The Movie")
        #expect(query.title == "Up - The Movie")
    }

    @Test func `empty result falls back to the raw name`() {
        let query = ContentIndexText.searchQuery(for: "4K")
        #expect(query.title == "4K")
    }

    // MARK: - document

    @Test func `document composes all parts in order`() {
        let document = ContentIndexText.document(for: .init(
            name: "Inception",
            year: 2010,
            genre: "Action, Science Fiction",
            tagline: "Your mind is the scene of the crime",
            plot: "A thief who steals corporate secrets.",
            cast: "Leonardo DiCaprio, Joseph Gordon-Levitt"
        ))
        #expect(document == "Inception (2010). Action, Science Fiction. "
            + "Your mind is the scene of the crime. A thief who steals corporate secrets. "
            + "Starring Leonardo DiCaprio, Joseph Gordon-Levitt.")
    }

    @Test func `document skips empty parts`() {
        let document = ContentIndexText.document(for: .init(
            name: "Inception",
            year: nil,
            genre: nil,
            tagline: "",
            plot: nil,
            cast: ""
        ))
        #expect(document == "Inception.")
    }

    // MARK: - year(fromReleaseDate:)

    @Test func `year parses ISO release dates`() {
        #expect(ContentIndexText.year(fromReleaseDate: "2010-07-16") == 2010)
        #expect(ContentIndexText.year(fromReleaseDate: "1972") == 1972)
        #expect(ContentIndexText.year(fromReleaseDate: nil) == nil)
        #expect(ContentIndexText.year(fromReleaseDate: "unknown") == nil)
    }

    // MARK: - Embedding blob coding

    @Test func `vector blob roundtrips`() {
        let vector: [Float] = [0.25, -1.5, 3.75, 0]
        let data = TextEmbedder.encode(vector)
        #expect(data.count == vector.count * MemoryLayout<Float>.stride)
        #expect(TextEmbedder.decode(data) == vector)
    }

    @Test func `empty vector roundtrips`() {
        let data = TextEmbedder.encode([])
        #expect(TextEmbedder.decode(data).isEmpty)
    }
}
