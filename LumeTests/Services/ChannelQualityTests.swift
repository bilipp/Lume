@testable import Lume
import Testing

struct ChannelQualityTests {
    private func key(_ name: String) -> String {
        ChannelQuality.parse(name).key
    }

    // MARK: - Shared keys

    @Test func `quality variants share one key`() {
        let names = ["DE: Lume Sport 1", "DE: Lume Sport 1 HD", "DE: Lume Sport 1 FHD", "DE: Lume Sport 1 4K", "DE: Lume Sport 1 UHD"]
        #expect(Set(names.map(key)) == ["de: lume sport 1"])
    }

    @Test func `parses quality and verbatim tag`() {
        let fhd = ChannelQuality.parse("DE: Lume Sport 1 FHD")
        #expect(fhd.quality == .fhd)
        #expect(fhd.tag == "FHD")

        let untagged = ChannelQuality.parse("DE: Lume Sport 1")
        #expect(untagged.quality == nil)
        #expect(untagged.tag == nil)

        let mixed = ChannelQuality.parse("Lume Sport 4K UHD")
        #expect(mixed.quality == .uhd)
        #expect(mixed.tag == "4K UHD")
    }

    @Test func `matching is case and diacritic insensitive`() {
        #expect(key("Orbit Eins hd") == key("orbit eins HD"))
        #expect(key("Télé Lumière HD") == key("TELE LUMIERE"))
    }

    @Test func `superscript tags are stripped`() {
        let superscript = ChannelQuality.parse("DE: Lume Sport 1 ᴴᴰ")
        #expect(superscript.key == "de: lume sport 1")
        #expect(superscript.quality == .hd)
        #expect(superscript.tag == "ᴴᴰ")
        #expect(ChannelQuality.parse("DE: Lume Sport 1 ᶠᴴᴰ").quality == .fhd)
        #expect(ChannelQuality.parse("DE: Lume Sport 1 ᵁᴴᴰ").quality == .uhd)
        #expect(ChannelQuality.parse("DE: Lume Sport 1 ⁴ᴷ").quality == .uhd)
        #expect(ChannelQuality.parse("LMXᴴᴰ").key == "lmx")
    }

    @Test func `bracketed tags drop their brackets`() {
        let paren = ChannelQuality.parse("Pitchside 1 (1080p)")
        #expect(paren.key == "pitchside 1")
        #expect(paren.quality == .fhd)
        #expect(paren.tag == "1080p")
        #expect(key("Pitchside 1 [FHD]") == "pitchside 1")
        #expect(key("Pitchside 1 [FHD HEVC]") == "pitchside 1")
        #expect(key("|HD| Pitchside 1") == key("Pitchside 1"))
        #expect(key("|UK| HD | Northbeam One") == key("|UK| Northbeam One"))
    }

    @Test func `codec tokens leave the key and join the tag`() {
        let hevc = ChannelQuality.parse("|UK| Northbeam One HEVC")
        #expect(hevc.key == key("|UK| Northbeam One"))
        #expect(hevc.quality == nil)
        #expect(hevc.tag == "HEVC")
        #expect(key("|UK| Northbeam One H.265") == key("|UK| Northbeam One"))
        #expect(key("|UK| Northbeam One H265") == key("|UK| Northbeam One"))
        #expect(ChannelQuality.parse("|UK| Northbeam One FHD H.265").tag == "FHD H.265")
    }

    @Test func `resolution tokens map to qualities`() {
        #expect(ChannelQuality.parse("Velvet 2160p").quality == .uhd)
        #expect(ChannelQuality.parse("Velvet 8K").quality == .uhd)
        #expect(ChannelQuality.parse("Velvet 720p").quality == .hd)
        #expect(ChannelQuality.parse("Velvet SD").quality == .sd)
        #expect(ChannelQuality.parse("Velvet 576p").quality == .sd)
        #expect([ChannelQuality.uhd, .sd, .fhd, .hd].sorted() == [.sd, .hd, .fhd, .uhd])
    }

    // MARK: - Never pair

    @Test func `channel numbers match whole words`() {
        #expect(key("Lume Sport 1 HD") != key("Lume Sport 10 HD"))
        #expect(key("Lume Sport 1") != key("Lume Sport 10 FHD"))
    }

    @Test func `brand suffixes stay distinct`() {
        #expect(key("Rivo HD") != key("Rivoneo HD"))
    }

    @Test func `country prefixes stay in the key`() {
        #expect(key("DE: Lume Sport 1 HD") != key("AT: Lume Sport 1 HD"))
        #expect(key("|UK| Northbeam One HD") == "|uk| northbeam one")
    }

    @Test func `timeshift markers stay in the key`() {
        #expect(key("Lume Eins +1") != key("Lume Eins HD"))
        #expect(key("Lume Eins HD +1") == key("Lume Eins +1"))
    }

    @Test func `a leading HD+ brand is not a tag`() {
        let brand = ChannelQuality.parse("HD+ Lume")
        #expect(brand.quality == nil)
        #expect(brand.tag == nil)
    }

    @Test func `channel numbers after the tag stay in the key`() {
        #expect(key("Lume Sport HD 1") == key("Lume Sport 1 FHD"))
        #expect(key("Lume Sport HD 1") != key("Lume Sport HD 2"))
    }

    @Test func `HDR is not HD`() {
        #expect(ChannelQuality.parse("Lume Nature HDR").quality == nil)
        #expect(ChannelQuality.parse("Lume Nature UHD HDR").quality == .uhd)
    }

    @Test func `HD inside other words is not a tag`() {
        #expect(ChannelQuality.parse("Shdtv").quality == nil)
        #expect(ChannelQuality.parse("UHDTV").quality == nil)
        #expect(ChannelQuality.parse("Movies HDRip").quality == nil)
    }

    @Test func `untagged raw and backup feeds stay distinct`() {
        #expect(key("Lume Sport 1 RAW") != key("Lume Sport 1 HD"))
        #expect(key("Lume Sport 1 Backup") != key("Lume Sport 1 HD"))
    }

    // MARK: - Feed descriptors after the tag

    @Test func `everything after the tag describes the feed`() {
        let names = [
            "Fieldcast 1", "Fieldcast 1 HDraw", "Fieldcast 1 HDraw²", "Fieldcast 1 HDraw Cable", "Fieldcast 1 FHD+",
            "Fieldcast 1 FHD (HEVC)", "Fieldcast 1 FHD Low (HEVC)", "Fieldcast 1 HD (HEVC)", "Fieldcast 1 HD (Web)"
        ]
        #expect(Set(names.map(key)) == ["fieldcast 1"])
        #expect(key("Fieldcast 1 HD (Web)") != key("Fieldcast 10 HD"))
        #expect(key("Lume Sport 1 HD Backup") == key("Lume Sport 1 FHD"))
        #expect(key("LMX HD+") == key("LMX HD"))
    }

    @Test func `the tag is the feed description verbatim`() {
        let raw = ChannelQuality.parse("Fieldcast 1 HDraw Cable")
        #expect(raw.tag == "HDraw Cable")
        #expect(raw.quality == .hd)

        let low = ChannelQuality.parse("Fieldcast 1 FHD Low (HEVC)")
        #expect(low.tag == "FHD Low (HEVC)")
        #expect(low.quality == .fhd)

        #expect(ChannelQuality.parse("Fieldcast 1 HDraw²").tag == "HDraw²")
        #expect(ChannelQuality.parse("Fieldcast 1 FHD+").quality == .fhd)
    }

    @Test func `glued tags read as their token in badges`() {
        #expect(ChannelQuality.badge(for: "Fieldcast 1 FHD+") == "FHD")
        #expect(ChannelQuality.badge(for: "Fieldcast 1 HDraw²") == "HD")
    }
}
