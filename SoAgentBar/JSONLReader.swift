import Foundation

// MARK: - ByteSource

/// 오프셋 기반으로 읽을 수 있는 바이트 원천 (JSONL 파일 추상화).
/// 테스트에서는 읽은 바이트 수를 세는 spy 구현으로 대체할 수 있다.
protocol ByteSource {
    /// 현재 원천의 전체 크기(바이트)
    var size: UInt64 { get }
    /// `offset`부터 원천의 끝까지 읽는다.
    func readToEnd(from offset: UInt64) -> Data
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

    func readToEnd(from offset: UInt64) -> Data {
        try? fileHandle.seek(toOffset: offset)
        return fileHandle.readDataToEndOfFile()
    }
}

// MARK: - JSONLReader

/// ByteSource의 `offset` 이후 "완성된 줄"만 JSON 객체로 파싱해 전달한다.
enum JSONLReader {

    /// - Returns: 완성된 줄을 소비했으면 다음 읽기 시작 오프셋, 소비한 줄이 없으면 nil
    ///   (UTF-8 디코딩에 실패해도 완성된 줄 범위만큼은 오프셋을 전진시킨다)
    static func readCompleteLines(
        from source: ByteSource,
        startingAt currentOffset: UInt64,
        onEvent: ([String: Any]) -> Void
    ) -> UInt64? {
        // 파일 크기 확인
        let fileSize = source.size
        guard fileSize > currentOffset else { return nil }

        // 새로 추가된 데이터만 읽기
        let newData = source.readToEnd(from: currentOffset)
        guard !newData.isEmpty else { return nil }

        // 마지막 개행 위치까지만 처리 — 파일 쓰는 도중인 불완전한 줄 제외
        // 개행이 없으면 아직 한 줄도 완성되지 않은 것이므로 전부 건너뜀
        let newlineByte = UInt8(ascii: "\n")
        guard let lastNewlineIdx = newData.lastIndex(of: newlineByte) else { return nil }

        // 완성된 줄까지만 슬라이싱 & 오프셋 전진
        // 나머지 부분 줄은 다음 폴링 때 재처리됨
        let completeData = newData[newData.startIndex...lastNewlineIdx]
        let nextOffset = currentOffset + UInt64(completeData.count)

        guard let text = String(data: completeData, encoding: .utf8) else { return nextOffset }

        // 완성된 줄만 파싱
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            onEvent(json)
        }
        return nextOffset
    }
}
