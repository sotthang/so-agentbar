import XCTest
@testable import SoAgentBar

// PERF-002: readCompleteLines가 offset~EOF 전체를 한 Data로 읽고 String/components/trim/data(using:)로
// 줄마다 복사본을 만들어, 1.4GB 파일에서 피크 메모리가 4~6GB까지 치솟았다.
// → 고정 크기 청크로 스트리밍하며 바이트 단위로 '\n' 분할, 상한 초과 줄은 버퍼링 없이 건너뛴다.

/// 메모리 내 바이트 원천 — 요청된 읽기 크기를 기록한다
private final class InMemoryByteSource: ByteSource {
    var bytes: Data
    private(set) var requestedCounts: [Int] = []

    init(_ bytes: Data) { self.bytes = bytes }
    convenience init(_ text: String) { self.init(Data(text.utf8)) }

    var size: UInt64 { UInt64(bytes.count) }

    func read(from offset: UInt64, upTo count: Int) -> Data {
        requestedCounts.append(count)
        let start = Int(min(offset, size))
        let end = min(start + count, bytes.count)
        return bytes.subdata(in: start..<end)
    }
}

final class JSONLReaderTests: XCTestCase {

    private func line(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)! + "\n"
    }

    private func read(
        _ source: ByteSource,
        from offset: UInt64 = 0,
        chunkSize: Int = 7,
        maxLineBytes: Int = 1024,
        stats: JSONLReader.Stats? = nil
    ) -> (events: [[String: Any]], next: UInt64?) {
        var events: [[String: Any]] = []
        let next = JSONLReader.readCompleteLines(
            from: source, startingAt: offset, chunkSize: chunkSize,
            maxLineBytes: maxLineBytes, stats: stats
        ) { events.append($0) }
        return (events, next)
    }

    // MARK: - 청크 경계를 걸친 줄 재조립

    func test_readCompleteLines_lineSpanningChunkBoundary_isReassembled() {
        let text = line(["type": "user", "index": 1]) + line(["type": "assistant", "index": 2])
        let source = InMemoryByteSource(text)

        let result = read(source, chunkSize: 7)

        XCTAssertEqual(result.events.compactMap { $0["index"] as? Int }, [1, 2])
        XCTAssertEqual(result.events.compactMap { $0["type"] as? String }, ["user", "assistant"])
        XCTAssertEqual(result.next, UInt64(Data(text.utf8).count))
    }
    // MARK: - 끝의 미완성 줄

    func test_readCompleteLines_trailingPartialLine_isNotEmittedAndOffsetStaysAtItsStart() {
        let complete = line(["type": "user", "index": 1])
        let partial = #"{"type":"assistant","ind"#
        let source = InMemoryByteSource(complete + partial)

        let result = read(source)

        XCTAssertEqual(result.events.compactMap { $0["index"] as? Int }, [1])
        XCTAssertEqual(result.next, UInt64(Data(complete.utf8).count), "오프셋은 미완성 줄의 시작에 머물러야 한다")
    }

    func test_readCompleteLines_onlyPartialLine_returnsNil() {
        let source = InMemoryByteSource(#"{"type":"user""#)

        let result = read(source)

        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNil(result.next)
    }

    // MARK: - 빈 줄 / CRLF / 공백 줄

    func test_readCompleteLines_emptyCRLFAndWhitespaceLines_areToleratedOrSkipped() {
        let text = "\n"
            + #"{"index":1}"# + "\r\n"
            + "   \t \n"
            + "  " + #"{"index":2}"# + "  \n"
            + "\r\n"
            + #"{"index":3}"# + "\n"
        let source = InMemoryByteSource(text)

        let result = read(source, chunkSize: 5)

        XCTAssertEqual(result.events.compactMap { $0["index"] as? Int }, [1, 2, 3])
        XCTAssertEqual(result.next, UInt64(Data(text.utf8).count))
    }

    // MARK: - 증분 추가

    func test_readCompleteLines_afterAppend_yieldsOnlyNewLines() {
        let first = line(["index": 1]) + line(["index": 2])
        let source = InMemoryByteSource(first + #"{"index":"#)
        let firstResult = read(source)
        XCTAssertEqual(firstResult.events.compactMap { $0["index"] as? Int }, [1, 2])
        let offset = try! XCTUnwrap(firstResult.next)

        // 미완성 줄이 마저 쓰이고 새 줄이 추가됨
        source.bytes.append(Data(("3}\n" + line(["index": 4])).utf8))
        let second = read(source, from: offset)

        XCTAssertEqual(second.events.compactMap { $0["index"] as? Int }, [3, 4])
        XCTAssertEqual(second.next, source.size)
        XCTAssertNil(read(source, from: source.size).next, "새 데이터가 없으면 nil")
    }
    // MARK: - 상한 초과 줄 건너뛰기

    func test_readCompleteLines_oversizedLine_isSkippedAndNextLineParsed() {
        let huge = line(["index": 1, "blob": String(repeating: "x", count: 500)])
        let text = huge + line(["index": 2]) + line(["index": 3])
        let source = InMemoryByteSource(text)
        let stats = JSONLReader.Stats()

        let result = read(source, chunkSize: 16, maxLineBytes: 64, stats: stats)

        XCTAssertEqual(result.events.compactMap { $0["index"] as? Int }, [2, 3])
        XCTAssertEqual(result.next, UInt64(Data(text.utf8).count), "초과 줄 뒤로 오프셋이 전진해야 한다")
        XCTAssertLessThanOrEqual(stats.maxBufferedBytes, 16 + 64, "초과 줄을 통째로 버퍼링하면 안 된다")
    }

    /// 한 청크 안에 통째로 들어온 줄도 상한을 넘으면 건너뛴다 (청크 크기와 무관하게 동일한 결과)
    func test_readCompleteLines_oversizedLineInsideSingleChunk_isSkipped() {
        let text = line(["index": 1, "blob": String(repeating: "x", count: 100)]) + line(["index": 2])
        let source = InMemoryByteSource(text)

        let result = read(source, chunkSize: 4096, maxLineBytes: 64)

        XCTAssertEqual(result.events.compactMap { $0["index"] as? Int }, [2])
        XCTAssertEqual(result.next, UInt64(Data(text.utf8).count))
    }

    // MARK: - 메모리 상한: 10MB 합성 파일

    func test_readCompleteLines_on10MBFile_boundsReadSizeAndInternalBuffer() throws {
        let chunkSize = 64 * 1024
        let maxLineBytes = 256 * 1024
        var text = ""
        var expected: [Int] = []
        var index = 0
        while text.utf8.count < 10 * 1024 * 1024 {
            // 다양한 길이의 줄 + 주기적으로 상한 초과 줄(1MB)을 섞는다
            let blobLength = index % 50 == 49 ? 1024 * 1024 : (index * 997) % 20_000
            text += line(["index": index, "blob": String(repeating: "a", count: blobLength)])
            if blobLength <= maxLineBytes - 100 { expected.append(index) }
            index += 1
        }
        let source = InMemoryByteSource(text)
        let stats = JSONLReader.Stats()

        let result = read(source, chunkSize: chunkSize, maxLineBytes: maxLineBytes, stats: stats)

        XCTAssertEqual(result.events.compactMap { $0["index"] as? Int }, expected)
        XCTAssertEqual(result.next, source.size)
        XCTAssertLessThanOrEqual(source.requestedCounts.max() ?? 0, chunkSize)
        XCTAssertGreaterThan(stats.maxBufferedBytes, 0)
        XCTAssertLessThanOrEqual(stats.maxBufferedBytes, chunkSize + maxLineBytes)
    }

    // MARK: - 크기 스냅샷

    func test_readCompleteLines_readsOnlyUpToSizeObservedAtStart() {
        let source = GrowingByteSource(Data(line(["index": 1]).utf8), appendOnRead: Data(line(["index": 2]).utf8))

        var events: [[String: Any]] = []
        let next = JSONLReader.readCompleteLines(from: source, startingAt: 0, chunkSize: 4) { events.append($0) }

        XCTAssertEqual(events.compactMap { $0["index"] as? Int }, [1], "호출 중 자라난 바이트는 다음 호출에서 처리")
        XCTAssertEqual(next, UInt64(Data(line(["index": 1]).utf8).count))
    }
}

/// 읽을 때마다 뒤에 바이트가 덧붙는 원천 (쓰기 중인 파일 재현)
private final class GrowingByteSource: ByteSource {
    private var bytes: Data
    private let appendOnRead: Data

    init(_ bytes: Data, appendOnRead: Data) {
        self.bytes = bytes
        self.appendOnRead = appendOnRead
    }

    var size: UInt64 { UInt64(bytes.count) }

    func read(from offset: UInt64, upTo count: Int) -> Data {
        let start = Int(min(offset, size))
        let end = min(start + count, bytes.count)
        let data = bytes.subdata(in: start..<end)
        bytes.append(appendOnRead)
        return data
    }
}
