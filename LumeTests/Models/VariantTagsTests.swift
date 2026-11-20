//
//  VariantTagsTests.swift
//  LumeTests
//

@testable import Lume
import Testing

struct VariantTagsTests {
    @Test func `quality labels`() {
        #expect(VariantTags(title: "Der Pate (1972) 4K").qualityLabel == "4K")
        #expect(VariantTags(title: "Der Pate (1972) UHD").qualityLabel == "UHD")
        #expect(VariantTags(title: "Der Pate 2160p").qualityLabel == "4K")
        #expect(VariantTags(title: "Der Pate FHD").qualityLabel == "FHD")
        #expect(VariantTags(title: "Der Pate (1080p)").qualityLabel == "FHD")
        #expect(VariantTags(title: "Der Pate HD").qualityLabel == "HD")
        #expect(VariantTags(title: "Der Pate SD").qualityLabel == "SD")
        #expect(VariantTags(title: "Der Pate").qualityLabel == nil)
    }

    @Test func `hdr and dolby vision flags`() {
        let hdr = VariantTags(title: "Dune (2021) 4K HDR10+")
        #expect(hdr.isHDR && !hdr.isDolbyVision && hdr.quality == .uhd)
        let dolby = VariantTags(title: "Dune (2021) 4K DV")
        #expect(dolby.isDolbyVision && !dolby.isHDR)
        #expect(VariantTags(title: "Dune Dolby Vision").isDolbyVision)
        let plain = VariantTags(title: "Dune (2021) FHD")
        #expect(!plain.isHDR && !plain.isDolbyVision)
    }

    @Test func `language from title tags`() {
        #expect(VariantTags(title: "DE | Der Pate (1972)").languageCode == "de")
        #expect(VariantTags(title: "Inception [ENG] FHD").languageCode == "en")
        #expect(VariantTags(title: "Inception (GER)").languageCode == "de")
        #expect(VariantTags(title: "FR: Amélie").languageCode == "fr")
        #expect(VariantTags(title: "UK - Sherlock").languageCode == "en")
        #expect(VariantTags(title: "|SE| Millennium").languageCode == "sv")
    }

    @Test func `title words and quality tags are not languages`() {
        #expect(VariantTags(title: "It (2017)").languageCode == nil)
        #expect(VariantTags(title: "The French Connection").languageCode == nil)
        #expect(VariantTags(title: "Movie (SD)").languageCode == nil)
        #expect(VariantTags(title: "Movie [DV]").languageCode == nil)
        #expect(VariantTags(title: "[MULTI] Inception").languageCode == nil)
    }

    @Test func `language falls back to the category name`() {
        #expect(VariantTags(title: "Inception", categoryName: "DE | Filme").languageCode == "de")
        #expect(VariantTags(title: "Inception", categoryName: "German Movies").languageCode == "de")
        #expect(VariantTags(title: "Inception", categoryName: "Movies [FR]").languageCode == "fr")
        #expect(VariantTags(title: "EN | Inception", categoryName: "DE | Filme").languageCode == "en")
        #expect(VariantTags(title: "Inception", categoryName: "Movies 4K").languageCode == nil)
    }

    @Test func `rank puts quality first then preferred language`() {
        let preferred = ["de", "en"]
        let uhdEnglish = VariantTags(title: "EN | Dune 4K").rank(preferredLanguages: preferred)
        let fhdGerman = VariantTags(title: "DE | Dune FHD").rank(preferredLanguages: preferred)
        let fhdEnglish = VariantTags(title: "EN | Dune FHD").rank(preferredLanguages: preferred)
        let fhdFrench = VariantTags(title: "FR | Dune FHD").rank(preferredLanguages: preferred)
        let untagged = VariantTags(title: "Dune").rank(preferredLanguages: preferred)
        let sorted = [untagged, fhdFrench, fhdEnglish, uhdEnglish, fhdGerman].sorted()
        #expect(sorted == [uhdEnglish, fhdGerman, fhdEnglish, fhdFrench, untagged])
    }

    @Test func `rank without preferences ties on language`() {
        let german = VariantTags(title: "DE | Dune FHD").rank(preferredLanguages: [])
        let english = VariantTags(title: "EN | Dune FHD").rank(preferredLanguages: [])
        #expect(!(german < english) && !(english < german))
        #expect(VariantTags(title: "Dune SD").rank(preferredLanguages: []) == VariantTags(title: "Dune").rank(preferredLanguages: []))
    }
}
