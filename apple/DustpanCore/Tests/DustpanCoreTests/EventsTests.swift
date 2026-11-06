import Testing
@testable import DustpanCore

@Suite struct EventParsing {
    func parse(_ text: String) -> [JSON] {
        var parser = EventParser()
        return text.utf8.compactMap { parser.feed(byte: $0) }
    }

    @Test func opsEventsYieldTheirData() {
        let stream = ": connected\n\nevent: ops\ndata: {\"cursor\":158}\n\n: ping\n\nevent: ops\r\ndata: {}\r\n\r\n"
        #expect(parse(stream) == [["cursor": 158], [:]])
    }

    @Test func otherEventsAndBadDataAreSafe() {
        #expect(parse("event: other\ndata: {\"cursor\":1}\n\nevent: ops\ndata: nonsense\n\n") == [[:]])
    }
}
