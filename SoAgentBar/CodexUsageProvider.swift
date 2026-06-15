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

        var result: [String: ClaudeSession.TokenUsage] = [:]
        var currentModel: String = ""
        var pendingTokenInfo: [String: Any]? = nil

        guard let content = String(data: jsonlData, encoding: .utf8) else { return [:] }
        let lines = content.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""
            let outerPayload = json["payload"] as? [String: Any]

            switch type {
            case "turn_context":
                guard let payload = outerPayload else { continue }
                if let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                    // 보류된 토큰이 있으면 결합
                    if let pending = pendingTokenInfo {
                        applySnapshot(info: pending, model: currentModel, result: &result)
                        pendingTokenInfo = nil
                    }
                }

            case "event_msg":
                guard let innerPayload = outerPayload else { continue }
                let innerType = innerPayload["type"] as? String ?? ""
                if innerType == "token_count" {
                    guard let info = innerPayload["info"] as? [String: Any],
                          info["total_token_usage"] is [String: Any] else { continue }
                    if !currentModel.isEmpty {
                        applySnapshot(info: info, model: currentModel, result: &result)
                    } else {
                        // model 미정 — 보류
                        pendingTokenInfo = info
                    }
                }

            default:
                break
            }
        }

        return result
    }

    /// info["total_token_usage"]를 파싱해 model 키로 덮어쓰기 (rev6 의미론)
    private nonisolated static func applySnapshot(
        info: [String: Any],
        model: String,
        result: inout [String: ClaudeSession.TokenUsage]
    ) {
        guard let usage = info["total_token_usage"] as? [String: Any] else { return }
        let input     = (usage["input_tokens"]            as? Int) ?? 0
        let cached    = (usage["cached_input_tokens"]     as? Int) ?? 0
        let output    = (usage["output_tokens"]           as? Int) ?? 0
        let reasoning = (usage["reasoning_output_tokens"] as? Int) ?? 0

        // 누적 X — 마지막 값으로 덮어쓰기 (rev6)
        result[model] = ClaudeSession.TokenUsage(
            input: input,
            cachedInput: cached,
            output: output,
            reasoningOutput: reasoning
        )
    }

    // MARK: - 세션 간 합산

    /// 세션별 마지막 스냅샷을 세션 간 "합산" → 모델별 합계 (R1.2, AC-1.1).
    nonisolated static func aggregate(
        root: URL,
        now: Date,
        fileManager: FileManager
    ) -> [String: ClaudeSession.TokenUsage] {
        let files = discoverRolloutFiles(root: root, now: now, fileManager: fileManager)
        guard !files.isEmpty else { return [:] }

        var combined: [String: ClaudeSession.TokenUsage] = [:]

        for file in files {
            guard let data = fileManager.contents(atPath: file.path) else { continue }
            let snapshot = lastSnapshot(jsonlData: data)
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
        fileManager: FileManager
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

        let tokensByModel = aggregate(root: root, now: now, fileManager: fileManager)
        let estimate = estimateInfo(from: tokensByModel, windowHours: windowHours)

        return ProviderUsage(id: .codex, state: .data, isEstimate: true, quota: nil, estimate: estimate)
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
        let now = Date()

        let usage = await Task.detached(priority: .utility) {
            CodexUsageAggregator.buildUsage(root: root, now: now, fileManager: fm)
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
