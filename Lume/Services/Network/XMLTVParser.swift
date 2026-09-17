//
//  XMLTVParser.swift
//  Lume
//
//  Streaming SAX parser for XMLTV EPG payloads
//

import Foundation

/// A parsed XMLTV programme ready for direct insertion.
struct ParsedProgramme {
    let channelId: String
    let title: String
    let description: String
    let start: Date
    let end: Date
}

/// Streaming SAX parser that yields batches via a callback to keep memory flat.
final nonisolated class XMLTVParser: NSObject, XMLParserDelegate {
    private var batch: [ParsedProgramme] = []
    private let batchSize: Int
    private let onBatch: ([ParsedProgramme]) -> Void
    private(set) var totalCount: Int = 0

    private var currentStart: String?
    private var currentStop: String?
    private var currentChannel: String?
    private var currentTitle: String?
    private var currentDesc: String?
    private var currentText: String = ""

    init(batchSize: Int = 2000, onBatch: @escaping ([ParsedProgramme]) -> Void) {
        self.batchSize = batchSize
        self.onBatch = onBatch
    }

    /// Parse an XMLTV file from disk, calling `onBatch` for every `batchSize` programmes.
    static func parse(fileURL: URL, batchSize: Int = 2000, onBatch: @escaping ([ParsedProgramme]) -> Void) -> Int {
        guard let xmlParser = XMLParser(contentsOf: fileURL) else { return 0 }
        let delegate = XMLTVParser(batchSize: batchSize, onBatch: onBatch)
        xmlParser.delegate = delegate
        xmlParser.parse()
        // Flush remaining
        if !delegate.batch.isEmpty {
            onBatch(delegate.batch)
        }
        return delegate.totalCount
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        if elementName == "programme" {
            currentStart = attributeDict["start"]
            currentStop = attributeDict["stop"]
            currentChannel = attributeDict["channel"]
            currentTitle = nil
            currentDesc = nil
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if elementName == "programme" {
            if let startDate = XMLTVDate.parse(currentStart),
               let endDate = XMLTVDate.parse(currentStop),
               let channel = currentChannel,
               let title = currentTitle, !title.isEmpty
            {
                batch.append(ParsedProgramme(
                    channelId: channel,
                    title: title,
                    description: currentDesc ?? "",
                    start: startDate,
                    end: endDate
                ))
                totalCount += 1

                if batch.count >= batchSize {
                    onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            currentStart = nil
            currentStop = nil
            currentChannel = nil
            currentTitle = nil
            currentDesc = nil
        } else if elementName == "title" {
            currentTitle = (currentTitle ?? "") + currentText
        } else if elementName == "desc" {
            currentDesc = (currentDesc ?? "") + currentText
        }
    }
}
