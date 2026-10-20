import Foundation

// MARK: - ByteSource

/// 오프셋 기반으로 읽을 수 있는 바이트 원천 (JSONL 파일 추상화).
/// 테스트에서는 읽은 바이트 수를 세는 spy 구현으로 대체할 수 있다.
protocol ByteSource {
    /// 현재 원천의 전체 크기(바이트)
    var size: UInt64 { get }
    /// `offset`부터 최대 `count` 바이트를 읽는다 (끝에 도달하면 더 짧거나 빈 Data).
    func read(from offset: UInt64, upTo count: Int) -> Data
}

/// FileHandle 기반 실제 파일 ByteSource. 인스턴스 해제 시 핸들을 닫는다.
final class FileByteSource: ByteSource {
    private let fileHandle: FileHandle

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        fileHandle = handle
    }

    deinit {
        try? fileHandle.close()
    }

    var size: UInt64 {
        (try? fileHandle.seekToEnd()) ?? 0
    }

    func read(from offset: UInt64, upTo count: Int) -> Data {
        guard (try? fileHandle.seek(toOffset: offset)) != nil else { return Data() }
        return (try? fileHandle.read(upToCount: count)) ?? Data()
    }
}

// MARK: - JSONLReader

/// ByteSource의 `offset` 이후 "완성된 줄"만 JSON 객체로 파싱해 전달한다.
///
/// 메모리 상한(PERF-002): 파일 전체가 아니라 `chunkSize` 단위로 스트리밍하며 바이트 수준에서 '\n'으로
/// 나눈다. 청크 경계에 걸친 줄만 별도 버퍼에 이어 붙이므로 내부 버퍼는 최대 `chunkSize + maxLineBytes`.
enum JSONLReader {

    /// 한 번에 읽는 청크 크기 (조정 가능한 상수)
    static let defaultChunkSize = 1 << 20      // 1 MiB
    /// 한 줄의 최대 크기. 넘는 줄은 통째로 버퍼링하지 않고 다음 '\n'까지 버린 뒤 건너뛴다.
    static let defaultMaxLineBytes = 8 << 20   // 8 MiB

    /// 테스트용 계측 — 내부 버퍼(현재 청크 + 미완성 줄)의 최대 바이트 수(high-water mark)
    final class Stats {
        fileprivate(set) var maxBufferedBytes = 0

        fileprivate func observe(_ bufferedBytes: Int) {
            maxBufferedBytes = max(maxBufferedBytes, bufferedBytes)
        }
    }

    /// - Parameters:
    ///   - chunkSize: 한 번에 요청하는 최대 바이트 수 (테스트에서 작게 주입)
    ///   - maxLineBytes: 이보다 긴 줄('\n' 제외)은 파싱하지 않고 건너뛴다 (오프셋은 그 뒤로 전진)
    ///   - stats: 버퍼 high-water mark 계측 (테스트 전용, 기본 nil)
    /// - Returns: 완성된 줄을 소비했으면 다음 읽기 시작 오프셋, 소비한 줄이 없으면 nil
    ///   (파싱에 실패한 줄도 완성된 줄이면 오프셋은 그 뒤로 전진한다)
    ///
    /// 크기 스냅샷: 호출 시작 시점의 `source.size`까지만 읽는다. 읽는 동안 파일이 계속 자라도
    /// 그 뒤 바이트는 다음 호출에서 처리한다 (계속 커지는 파일을 끝없이 쫓지 않기 위함).
    static func readCompleteLines(
        from source: ByteSource,
        startingAt currentOffset: UInt64,
        chunkSize: Int = defaultChunkSize,
        maxLineBytes: Int = defaultMaxLineBytes,
        stats: Stats? = nil,
        onEvent: ([String: Any]) -> Void
    ) -> UInt64? {
        let endOffset = source.size
        guard endOffset > currentOffset else { return nil }

        let newlineByte = UInt8(ascii: "\n")
        var readOffset = currentOffset       // 다음 청크를 읽을 위치
        var committedOffset = currentOffset  // 마지막으로 완성된 줄의 다음 위치
        var partialLine = Data()             // 청크 경계에 걸친 미완성 줄 (최대 maxLineBytes)
        var isDiscardingLine = false         // 상한 초과 줄을 다음 '\n'까지 버리는 중

        func emit(_ lineData: Data) {
            // 줄마다 autorelease pool을 비워 파싱 중간 객체가 전체 파일 분량만큼 쌓이지 않게 한다 (PERF-003)
            autoreleasepool {
                guard !lineData.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { return }
                onEvent(json)
            }
        }

        while readOffset < endOffset {
            let wanted = Int(min(UInt64(chunkSize), endOffset - readOffset))
            let chunkStart = readOffset
            let chunk = autoreleasepool { source.read(from: chunkStart, upTo: wanted) }
            if chunk.isEmpty { break }
            readOffset += UInt64(chunk.count)

            var segmentStart = chunk.startIndex
            while let newlineIdx = chunk[segmentStart...].firstIndex(of: newlineByte) {
                let segment = chunk[segmentStart..<newlineIdx]
                if isDiscardingLine || partialLine.count + segment.count > maxLineBytes {
                    isDiscardingLine = false
                } else if partialLine.isEmpty {
                    emit(segment)
                } else {
                    partialLine.append(segment)
                    stats?.observe(chunk.count + partialLine.count)
                    emit(partialLine)
                }
                partialLine = Data()
                segmentStart = newlineIdx + 1
                committedOffset = chunkStart + UInt64(segmentStart - chunk.startIndex)
            }
            let remainder = chunk[segmentStart...]
            if !isDiscardingLine {
                if partialLine.count + remainder.count > maxLineBytes {
                    isDiscardingLine = true
                    partialLine = Data()
                } else {
                    partialLine.append(remainder)
                }
            }
            stats?.observe(chunk.count + partialLine.count)
        }

        return committedOffset > currentOffset ? committedOffset : nil
    }
}
