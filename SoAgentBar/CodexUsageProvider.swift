import Foundation

// MARK: - CodexUsageAggregator (순수 집계기 — TDD 핵심 대상)
//
// 24시간 롤링 윈도우 내 Codex 세션 JSONL에서
// 각 세션의 마지막 토큰 스냅샷만 추출해 세션 간 합산한다.
// (R1.2, R1.4, AC-1.1, AC-1.5)
//
// 역할:
// - ~/.codex/sessions YYYY/MM/DD/rollout-*.jsonl 파일 탐색 (24h 윈도우, 디렉토리 미생성)
// - 각 파일을 JSONL으로 파싱하여 turn_context(모델) + token_count(토큰) 이벤트 추출
// - 각 세션의 마지막 모델별 토큰만 누적 (applyTokenSnapshot rev6 의미론 재현)
// - CostCalculator로 비용 추정
// - "비용 추정 불가" 케이스 구분 (단가 0/미상)
// nonisolated static 함수들이 순수 함수로 설계되어 단위 테스트 가능 (NFR2).

enum CodexUsageAggregator {

    // MARK: - 상수

    /// 롤링 윈도우 (R1.4): 24h = 86400s
    static let rollingWindowSeconds: TimeInterval = 86400

    /// EstimateInfo.windowHours 계약값 (R1.4)
    static let windowHours: Int = 24

    /// 디렉토리/데이터 부재 시 반환하는 공통 스냅샷 (중복 리터럴 제거)
    private static let needsSetupUsage = ProviderUsage(
        id: .codex, state: .needsSetup, isEstimate: true, quota: nil, estimate: nil
    )

    // MARK: - 파일 탐색 (24h 롤링 윈도우, 디렉토리 미생성)

    /// 24h 윈도우 내 rollout 파일 발견.
    /// CodexSessionMonitor.discoverRolloutFiles와 동일 규칙:
    ///   YYYY/MM/DD/*.jsonl, .zst 무시, rollingWindowSeconds 필터.
    /// 디렉토리 미생성.
    nonisolated static func discoverRolloutFiles(
        root: URL,
        now: Date,
        fileManager: FileManager
    ) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        var results: [URL] = []

        // YYYY/MM/DD 형태의 3단계 디렉토리를 재귀 탐색
        guard let yearDirs = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for yearDir in yearDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: yearDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let monthDirs = try? fileManager.contentsOfDirectory(
                at: yearDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for monthDir in monthDirs {
                guard fileManager.fileExists(atPath: monthDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

                guard let dayDirs = try? fileManager.contentsOfDirectory(
                    at: monthDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for dayDir in dayDirs {
                    guard fileManager.fileExists(atPath: dayDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

                    guard let files = try? fileManager.contentsOfDirectory(
                        at: dayDir,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for file in files {
                        // .zst 무시
                        if file.pathExtension == "zst" { continue }
                        // .jsonl 만 허용
                        guard file.pathExtension == "jsonl" else { continue }

                        // 수정 시각 기반 rollingWindowSeconds 필터
                        guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                              let modDate = attrs[.modificationDate] as? Date else { continue }

                        // CodexSessionMonitor와 동일 규칙
                        guard now.timeIntervalSince(modDate) < rollingWindowSeconds else { continue }

                        results.append(file)
                    }
                }
            }
        }

        return results
    }

    // MARK: - 단일 세션 마지막 스냅샷 추출

    /// 한 JSONL 파일 → 그 세션의 "마지막" 모델별 토큰 스냅샷.
    /// applyTokenSnapshot 의미론(누적 X, 마지막 값 덮어쓰기 rev6) 재현.
    /// turn_context.model과 token_count.info["total_token_usage"] 결합.
    nonisolated static func lastSnapshot(
        jsonlData: Data
    ) -> [String: ClaudeSession.TokenUsage] {
        guard !jsonlData.isEmpty else { return [:] }

        var state = TokenSnapshotState()

        guard let content = String(data: jsonlData, encoding: .utf8) else { return [:] }
        let lines = content.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            state.consume(json)
        }

        return state.result
    }

    /// 한 세션 JSONL을 줄 순서대로 소비하며 모델별 마지막 토큰 스냅샷을 누적하는 상태.
    /// 줄 단위로 이어서 소비할 수 있어 파일 일부만 읽는 증분 집계에도 쓴다.
    struct TokenSnapshotState {
        /// 모델별 마지막 토큰 스냅샷
        private(set) var result: [String: ClaudeSession.TokenUsage] = [:]
        private var currentModel: String = ""
        /// model 도착 전 token_count (첫 turn_context.model과 결합 대기)
        private var pendingTokens: ClaudeSession.TokenUsage? = nil

        mutating func consume(_ json: [String: Any]) {
            let type = json["type"] as? String ?? ""
            let outerPayload = json["payload"] as? [String: Any]

            switch type {
            case "turn_context":
                guard let payload = outerPayload else { return }
                if let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                    // 보류된 토큰이 있으면 결합
                    if let pending = pendingTokens {
                        result[currentModel] = pending
                        pendingTokens = nil
                    }
                }

            case "event_msg":
                guard let innerPayload = outerPayload else { return }
                let innerType = innerPayload["type"] as? String ?? ""
                if innerType == "token_count" {
                    guard let info = innerPayload["info"] as? [String: Any],
                          let tokens = CodexUsageAggregator.tokenUsage(from: info) else { return }
                    if !currentModel.isEmpty {
                        // 누적 X — 마지막 값으로 덮어쓰기 (rev6)
                        result[currentModel] = tokens
                    } else {
                        // model 미정 — 보류
                        pendingTokens = tokens
                    }
                }

            default:
                break
            }
        }
    }

    /// info["total_token_usage"] → TokenUsage (없으면 nil)
    fileprivate nonisolated static func tokenUsage(from info: [String: Any]) -> ClaudeSession.TokenUsage? {
        guard let usage = info["total_token_usage"] as? [String: Any] else { return nil }
        return ClaudeSession.TokenUsage(
            input:           (usage["input_tokens"]            as? Int) ?? 0,
            cachedInput:     (usage["cached_input_tokens"]     as? Int) ?? 0,
            output:          (usage["output_tokens"]           as? Int) ?? 0,
            reasoningOutput: (usage["reasoning_output_tokens"] as? Int) ?? 0
        )
    }

    // MARK: - 세션 간 합산

    /// 세션별 마지막 스냅샷을 세션 간 "합산" → 모델별 합계 (R1.2, AC-1.1).
    /// - scanCache: 파일별 증분 스캔 상태. 폴링 사이에 유지하면 변경 없는 파일은 다시 읽지 않는다 (PERF-007).
    ///   기본값(새 캐시)이면 매번 처음부터 읽되, 파일 전체가 아닌 청크 단위로 스트리밍한다.
    nonisolated static func aggregate(
        root: URL,
        now: Date,
        fileManager: FileManager,
        scanCache: CodexUsageScanCache = CodexUsageScanCache()
    ) -> [String: ClaudeSession.TokenUsage] {
        let files = discoverRolloutFiles(root: root, now: now, fileManager: fileManager)
        let snapshots = scanCache.snapshots(for: files, fileManager: fileManager)
        guard !snapshots.isEmpty else { return [:] }

        var combined: [String: ClaudeSession.TokenUsage] = [:]

        for snapshot in snapshots {
            for (model, tokens) in snapshot {
                let existing = combined[model] ?? ClaudeSession.TokenUsage()
                combined[model] = ClaudeSession.TokenUsage(
                    input:          existing.input          + tokens.input,
                    cachedInput:    existing.cachedInput    + tokens.cachedInput,
                    output:         existing.output         + tokens.output,
                    reasoningOutput: existing.reasoningOutput + tokens.reasoningOutput
                )
            }
        }

        return combined
    }

    // MARK: - 비용 추정

    /// 모델별 토큰 → EstimateInfo (CostCalculator.estimate 사용).
    /// 단가 0/미상 모델은 비용 nil로 합산 제외 → isCostUnavailable 표현 (C3, AC-1.2).
    nonisolated static func estimateInfo(
        from tokensByModel: [String: ClaudeSession.TokenUsage],
        windowHours: Int
    ) -> EstimateInfo {
        var totalTokens = 0
        var totalCost: Double? = nil

        for (model, tokens) in tokensByModel {
            let modelTotal = tokens.input + tokens.cachedInput + tokens.output + tokens.reasoningOutput
            totalTokens += modelTotal

            // CostCalculator.estimate: 단가 0이면 0.0 반환, 단가 미상이면 nil 반환
            // 0.0 또는 nil → 비용 합산에서 제외 (C3: 단가 0/미상 모델은 costDollars nil)
            if let cost = CostCalculator.estimate(
                model: model,
                inputTokens: tokens.input,
                cachedInputTokens: tokens.cachedInput,
                outputTokens: tokens.output
            ), cost > 0 {
                // 비용 산출 가능한 모델만 합산
                totalCost = (totalCost ?? 0) + cost
            }
            // cost == 0.0 (단가 0, gpt-5-codex) 또는 nil (단가 미상) → 합산 제외
        }

        return EstimateInfo(totalTokens: totalTokens, costDollars: totalCost, windowHours: windowHours)
    }

    // MARK: - ProviderUsage 빌드

    /// 디렉토리/데이터 없음 → ProviderUsage(state: .needsSetup) (R1.5, AC-1.4).
    nonisolated static func buildUsage(
        root: URL,
        now: Date,
        fileManager: FileManager,
        scanCache: CodexUsageScanCache = CodexUsageScanCache()
    ) -> ProviderUsage {
        // 디렉토리 없으면 needsSetup (디렉토리 생성 안 함)
        guard fileManager.fileExists(atPath: root.path) else {
            return needsSetupUsage
        }

        let files = discoverRolloutFiles(root: root, now: now, fileManager: fileManager)

        // 롤링 윈도우 내 파일 없으면 needsSetup
        guard !files.isEmpty else {
            return needsSetupUsage
        }

        let tokensByModel = aggregate(root: root, now: now, fileManager: fileManager, scanCache: scanCache)
        let estimate = estimateInfo(from: tokensByModel, windowHours: windowHours)

        return ProviderUsage(id: .codex, state: .data, isEstimate: true, quota: nil, estimate: estimate)
    }
}

// MARK: - CodexUsageScanCache (PERF-007)

/// rollout 파일별 증분 스캔 상태 캐시.
///
/// 폴링마다 모든 rollout 파일을 통째로 메모리에 읽고(`contents(atPath:)`) 줄 단위로 재파싱하던 것을 대체한다.
/// - 크기·mtime이 그대로인 파일은 열지도 않고 캐시된 스냅샷을 쓴다.
/// - 덧붙은 파일은 마지막으로 읽은 위치부터 새 바이트만 청크 단위로 읽는다 (JSONLReader, 줄 단위 autoreleasepool).
/// - 크기가 줄어든 파일(교체/절단)은 처음부터 다시 읽는다.
///
/// 역방향 스캔 대신 정방향 증분 스캔을 쓰는 이유: `lastSnapshot` 의미론은 "모델별" 마지막 스냅샷이라
/// 파일 앞부분에만 등장한 모델도 결과에 포함된다 — 끝에서 마지막 token_count 하나만 찾으면 결과가 달라진다.
/// 폴링 사이 Task.detached 실행이 겹칠 수 있어 내부 상태는 lock으로 직렬화한다.
final class CodexUsageScanCache: @unchecked Sendable {

    private struct Entry {
        var size: UInt64
        var modificationDate: Date
        var offset: UInt64
        var state: CodexUsageAggregator.TokenSnapshotState
    }

    private let chunkSize: Int
    private let makeByteSource: (URL) -> ByteSource?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(
        chunkSize: Int = JSONLReader.defaultChunkSize,
        makeByteSource: @escaping (URL) -> ByteSource? = { FileByteSource(url: $0) }
    ) {
        self.chunkSize = chunkSize
        self.makeByteSource = makeByteSource
    }

    /// 캐시에 남아 있는 파일 수 (테스트 계측용)
    var cachedFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// 주어진 파일들의 모델별 마지막 토큰 스냅샷. 목록에 없는 파일의 캐시 항목은 버린다.
    func snapshots(for files: [URL], fileManager: FileManager) -> [[String: ClaudeSession.TokenUsage]] {
        lock.lock()
        defer { lock.unlock() }

        var results: [[String: ClaudeSession.TokenUsage]] = []
        var activePaths: Set<String> = []
        for file in files {
            autoreleasepool {
                guard let attrs = try? fileManager.attributesOfItem(atPath: file.path),
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      let modDate = attrs[.modificationDate] as? Date else { return }
                activePaths.insert(file.path)
                let entry = updatedEntry(for: file, size: size, modificationDate: modDate)
                entries[file.path] = entry
                results.append(entry.state.result)
            }
        }
        for path in entries.keys where !activePaths.contains(path) {
            entries.removeValue(forKey: path)
        }
        return results
    }

    private func updatedEntry(for file: URL, size: UInt64, modificationDate: Date) -> Entry {
        if let cached = entries[file.path],
           cached.size == size, cached.modificationDate == modificationDate {
            return cached
        }

        // 크기가 줄었으면(교체/절단) 이전 상태를 버리고 처음부터
        var entry = entries[file.path].flatMap { $0.offset <= size ? $0 : nil }
            ?? Entry(size: 0, modificationDate: .distantPast, offset: 0, state: .init())
        entry.size = size
        entry.modificationDate = modificationDate

        guard let source = makeByteSource(file) else { return entry }
        var state = entry.state
        if let next = JSONLReader.readCompleteLines(
            from: source, startingAt: entry.offset, chunkSize: chunkSize,
            onEvent: { state.consume($0) }
        ) {
            entry.offset = next
        }
        // 개행 없이 끝난 마지막 줄: 완성된 JSON이면 소비한다 (기존 전체 읽기 방식도 집계했다).
        // 아직 쓰는 중이라 파싱에 실패하면 오프셋을 그대로 두고 다음 폴링에서 다시 본다.
        consumeTrailingLine(from: source, entry: &entry, state: &state)
        entry.state = state
        return entry
    }

    private func consumeTrailingLine(
        from source: ByteSource,
        entry: inout Entry,
        state: inout CodexUsageAggregator.TokenSnapshotState
    ) {
        let end = source.size
        guard end > entry.offset, end - entry.offset <= UInt64(JSONLReader.defaultMaxLineBytes) else { return }
        var tail = Data()
        var readOffset = entry.offset
        while readOffset < end {
            let chunk = source.read(from: readOffset, upTo: Int(min(UInt64(chunkSize), end - readOffset)))
            if chunk.isEmpty { return }
            tail.append(chunk)
            readOffset += UInt64(chunk.count)
        }
        guard !tail.contains(UInt8(ascii: "\n")) else { return }  // 그 사이 개행이 생겼으면 다음 폴링에서 정상 처리
        autoreleasepool {
            guard let json = try? JSONSerialization.jsonObject(with: tail) as? [String: Any] else { return }
            state.consume(json)
            entry.offset = end
        }
    }
}

// MARK: - CodexUsageProvider (MainActor 래퍼)

@MainActor
final class CodexUsageProvider: UsageProviderProtocol {
    nonisolated var id: ProviderID { .codex }
    var onUsageChanged: ((ProviderUsage) -> Void)?
    private(set) var currentUsage: ProviderUsage

    private let root: URL
    private let fileManager: FileManager
    /// 폴링 사이 유지되는 파일별 증분 스캔 상태 — 변경 없는 rollout 파일은 다시 읽지 않는다 (PERF-007)
    private let scanCache = CodexUsageScanCache()
    private var pollingTimer: Timer?
    /// 기본 폴링 간격 — UsageCoordinator.updatePollInterval이 호출되기 전까지 사용 (NFR3)
    private static let defaultPollInterval: TimeInterval = 300  // 5분

    init(
        root: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions"),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
        self.currentUsage = ProviderUsage.loading(.codex, isEstimate: true)
    }

    func start() {
        Task { await fetch() }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.defaultPollInterval, repeats: true) { [weak self] _ in
            Task { await self?.fetch() }
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    func fetch() async {
        let root = self.root
        let fm = self.fileManager
        let scanCache = self.scanCache
        let now = Date()

        let usage = await Task.detached(priority: .utility) {
            CodexUsageAggregator.buildUsage(root: root, now: now, fileManager: fm, scanCache: scanCache)
        }.value

        currentUsage = usage
        onUsageChanged?(usage)
    }

    func updatePollInterval(_ interval: Double) {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.fetch() }
        }
    }
}
