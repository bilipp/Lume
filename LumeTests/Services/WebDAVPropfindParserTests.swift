import Foundation
@testable import Lume
import Testing

/// Canned `207 Multi-Status` bodies. The Apache ones are byte-shaped like the
/// reference mod_dav share: properties arrive under a second prefix (`lp1:`)
/// that is also bound to `DAV:`, mixed with `D:` ones.
private enum PropfindFixtures {
    static let collection = URL(string: "http://nas.local:30035/Movies/")!

    /// Apache mod_dav, one file plus one subdirectory.
    static let apacheMixedPrefixes = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">
    <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/" xmlns:g0="DAV:">
    <D:href>/Movies/</D:href>
    <D:propstat>
    <D:prop>
    <lp1:resourcetype><D:collection/></lp1:resourcetype>
    <lp1:getlastmodified>Mon, 14 Sep 2026 09:57:00 GMT</lp1:getlastmodified>
    <lp1:getetag>"3-65b6e748e9bab"</lp1:getetag>
    <D:getcontenttype>httpd/unix-directory</D:getcontenttype>
    </D:prop>
    <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    <D:propstat>
    <D:prop>
    <g0:getcontentlength/>
    </D:prop>
    <D:status>HTTP/1.1 404 Not Found</D:status>
    </D:propstat>
    </D:response>
    <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
    <D:href>/Movies/Action/</D:href>
    <D:propstat>
    <D:prop>
    <lp1:resourcetype><D:collection/></lp1:resourcetype>
    <lp1:getlastmodified>Sun, 13 Sep 2026 08:00:00 GMT</lp1:getlastmodified>
    <D:getcontenttype>httpd/unix-directory</D:getcontenttype>
    </D:prop>
    <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    </D:response>
    <D:response xmlns:lp1="DAV:" xmlns:lp2="http://apache.org/dav/props/">
    <D:href>/Movies/Arrival.2016.1080p.mkv</D:href>
    <D:propstat>
    <D:prop>
    <lp1:resourcetype/>
    <lp1:getcontentlength>2806609208</lp1:getcontentlength>
    <lp1:getlastmodified>Mon, 14 Sep 2026 09:39:38 GMT</lp1:getlastmodified>
    <lp1:getetag>"a7497538-65b6e36779510"</lp1:getetag>
    <D:getcontenttype>video/x-matroska</D:getcontenttype>
    </D:prop>
    <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
    </D:response>
    </D:multistatus>
    """

    /// Nextcloud: a single lowercase `d:` prefix plus vendor namespaces.
    static let nextcloudLowercasePrefix = """
    <?xml version="1.0"?>
    <d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" \
    xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
    <d:response>
    <d:href>/Movies/</d:href>
    <d:propstat>
    <d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
    <d:getlastmodified>Mon, 14 Sep 2026 09:57:00 GMT</d:getlastmodified>
    <oc:size>2806609208</oc:size>
    </d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    </d:response>
    <d:response>
    <d:href>/Movies/Series/</d:href>
    <d:propstat>
    <d:prop>
    <d:resourcetype><d:collection/></d:resourcetype>
    <d:getetag>&quot;65b6e748e9bab&quot;</d:getetag>
    </d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    </d:response>
    <d:response>
    <d:href>/Movies/Dune.2021.2160p.mkv</d:href>
    <d:propstat>
    <d:prop>
    <d:resourcetype/>
    <d:getcontentlength>1234567</d:getcontentlength>
    <d:getcontenttype>video/x-matroska</d:getcontenttype>
    <d:getlastmodified>Fri, 11 Sep 2026 22:15:00 GMT</d:getlastmodified>
    </d:prop>
    <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    </d:response>
    </d:multistatus>
    """

    /// Scene release name whose brackets the server returns percent-encoded.
    static let bracketedFilename = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    <D:response xmlns:lp1="DAV:">
    <D:href>/Movies/</D:href>
    <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
    <D:response xmlns:lp1="DAV:">
    <D:href>/Movies/Harbor.Lights.S02E01.1080p.WEB.h264-NIGHT%5bIndexer.to%5d.mkv</D:href>
    <D:propstat><D:prop>
    <lp1:resourcetype/>
    <lp1:getcontentlength>2806609208</lp1:getcontentlength>
    <D:getcontenttype>video/x-matroska</D:getcontenttype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
    </D:multistatus>
    """

    /// A collection with no children at all.
    static let emptyCollection = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    <D:response xmlns:lp1="DAV:">
    <D:href>/Movies/</D:href>
    <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
    </D:multistatus>
    """

    /// `Depth: 0` — the collection describes only itself.
    static let collectionOnly = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
    <D:response xmlns:lp1="DAV:">
    <D:href>http://nas.local:30035/Movies</D:href>
    <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
    </D:response>
    </D:multistatus>
    """

    static let htmlIndexPage = """
    <!DOCTYPE html>
    <html><head><title>Index of /Movies</title></head>
    <body><h1>Index of /Movies</h1><ul><li><a href="a.mkv">a.mkv</a></li></ul></body></html>
    """
}

struct WebDAVPropfindParserTests {
    private func parse(_ body: String, collection: URL = PropfindFixtures.collection) -> [WebDAVResource]? {
        WebDAVPropfindParser.parse(Data(body.utf8), collection: collection)
    }

    @Test func `apache mod_dav mixed D and lp1 prefixes yield every child`() throws {
        let resources = try #require(parse(PropfindFixtures.apacheMixedPrefixes))

        #expect(resources.count == 2)
        let directory = try #require(resources.first { $0.isCollection })
        #expect(directory.name == "Action")
        #expect(directory.url.absoluteString == "http://nas.local:30035/Movies/Action/")

        let file = try #require(resources.first { !$0.isCollection })
        #expect(file.name == "Arrival.2016.1080p.mkv")
        #expect(file.url.absoluteString == "http://nas.local:30035/Movies/Arrival.2016.1080p.mkv")
        #expect(file.contentLength == 2_806_609_208)
        #expect(file.contentType == "video/x-matroska")
        #expect(file.etag == "\"a7497538-65b6e36779510\"")
        #expect(file.lastModified == Date(timeIntervalSince1970: 1_789_378_778))
    }

    @Test func `nextcloud lowercase d prefix parses the same way`() throws {
        let resources = try #require(parse(PropfindFixtures.nextcloudLowercasePrefix))

        #expect(resources.count == 2)
        #expect(resources.first?.name == "Series")
        #expect(resources.first?.isCollection == true)
        #expect(resources.last?.name == "Dune.2021.2160p.mkv")
        #expect(resources.last?.isCollection == false)
        #expect(resources.last?.contentLength == 1_234_567)
    }

    /// Re-encoding would give `%255b` (404); decoding gives a literal `[` that
    /// `URL(string:)` rejects. The href must survive byte for byte.
    @Test func `percent-encoded brackets survive in the URL and decode in the name`() throws {
        let resources = try #require(parse(PropfindFixtures.bracketedFilename))
        let file = try #require(resources.first)

        #expect(resources.count == 1)
        #expect(file.url.absoluteString.hasSuffix("h264-NIGHT%5bIndexer.to%5d.mkv"))
        #expect(file.name == "Harbor.Lights.S02E01.1080p.WEB.h264-NIGHT[Indexer.to].mkv")
        #expect(file.contentLength == 2_806_609_208)
    }

    @Test func `an empty collection yields no resources`() throws {
        #expect(try #require(parse(PropfindFixtures.emptyCollection)).isEmpty)
    }

    /// The response describing the collection itself must never become a row:
    /// it would give every directory a phantom child and make the recursive
    /// walk descend into itself forever.
    @Test func `a collection-only response yields no resources`() throws {
        #expect(try #require(parse(PropfindFixtures.collectionOnly)).isEmpty)
    }

    @Test func `an HTML index page is not a multistatus`() {
        #expect(parse(PropfindFixtures.htmlIndexPage) == nil)
    }

    @Test func `a non-XML body is not a multistatus`() {
        #expect(parse("not xml at all") == nil)
    }
}
