import Foundation

/// The deliberately narrow HLS input contract for the first timeshift backend.
/// Unsupported manifests must keep playing through the ordinary live path.
nonisolated struct TimeshiftPlaylist {
    struct Segment: Equatable {
        let sequence: Int64
        let duration: TimeInterval
        let url: URL
        let discontinuity: Bool
    }

    enum ParseError: Error, Equatable {
        case malformed
        case unsupported
    }

    let segments: [Segment]
    let targetDuration: TimeInterval
    let isFinished: Bool

    init(text: String, baseURL: URL) throws {
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard lines.first == "#EXTM3U" else { throw ParseError.malformed }
        var sequence: Int64 = 0
        var target: TimeInterval?
        var duration: TimeInterval?
        var discontinuity = false
        var result: [Segment] = []
        var finished = false
        for line in lines.dropFirst() {
            try Self.validateTag(line)
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard result.isEmpty else { throw ParseError.malformed }
                sequence = try Self.sequenceNumber(String(line.dropFirst(22)))
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = try Self.positiveDuration(String(line.dropFirst(22)))
            } else if line.hasPrefix("#EXTINF:") {
                guard duration == nil else { throw ParseError.malformed }
                duration = try Self.positiveDuration(String(line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false)[0]))
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if line == "#EXT-X-ENDLIST" {
                finished = true
            } else if !line.hasPrefix("#") {
                try result.append(Self.segment(line: line, duration: duration, sequence: sequence,
                                               discontinuity: discontinuity, baseURL: baseURL))
                sequence += 1
                duration = nil
                discontinuity = false
            }
        }
        targetDuration = try Self.finalDuration(target, pending: duration, segments: result)
        segments = result
        isFinished = finished
    }

    private static func finalDuration(_ target: Double?, pending: Double?, segments: [Segment]) throws -> Double {
        guard let target, pending == nil, !segments.isEmpty else { throw ParseError.malformed }
        return target
    }

    private static func sequenceNumber(_ text: String) throws -> Int64 {
        guard let value = Int64(text), value >= 0 else { throw ParseError.malformed }
        return value
    }

    private static func positiveDuration(_ text: String) throws -> Double {
        guard let value = Double(text), value.isFinite, value > 0, value <= 86400 else { throw ParseError.malformed }
        return value
    }

    private static func validateTag(_ line: String) throws {
        // Key rotation, alternate renditions, byte ranges and init segments
        // need their own cache ownership; never silently drop those tags.
        if ["#EXT-X-STREAM-INF", "#EXT-X-I-FRAME", "#EXT-X-MEDIA:",
            "#EXT-X-KEY:", "#EXT-X-SESSION-KEY:", "#EXT-X-MAP:",
            "#EXT-X-BYTERANGE:", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT",
            "#EXT-X-SKIP:", "#EXT-X-GAP"].contains(where: { line.hasPrefix($0) })
        {
            throw ParseError.unsupported
        }
    }

    private static func segment(line: String, duration: TimeInterval?, sequence: Int64,
                                discontinuity: Bool, baseURL: URL) throws -> Segment
    {
        guard let duration, sequence < Int64.max,
              let url = URL(string: line, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ParseError.malformed }
        return Segment(sequence: sequence, duration: duration, url: url, discontinuity: discontinuity)
    }
}
