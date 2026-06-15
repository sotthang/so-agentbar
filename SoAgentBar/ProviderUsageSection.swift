import SwiftUI

// MARK: - ProviderUsageSection (프로바이더 1개 단위 섹션, design.md 컴포넌트 2)
//
// state 분기: loading / needsSetup / error / data / disabledFallback
// data 분기: quota(Claude) vs estimate(Codex/Gemini)
// 기존 UsageView의 상태 분기/quotaRow/Extra 본문을 이식 (회귀 없음, NFR5)

struct ProviderUsageSection: View {
    let usage: ProviderUsage
    @ObservedObject var store: AgentStore
    let onRetry: () -> Void

    var body: some View {
        switch usage.state {
        case .loading:
            loadingBody
        case .needsSetup:
            needsSetupBody
        case .error(let message):
            errorBody(message: message)
        case .data:
            dataBody
        case .disabledFallback:
            disabledFallbackBody
        }
    }

    // MARK: - loading

    private var loadingBody: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.6)
            Text(usage.id == .claude
                 ? store.t("쿼터 로딩 중...", "Loading quota...")
                 : store.t("사용량 로딩 중...", "Loading usage..."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - needsSetup

    private var needsSetupBody: some View {
        HStack(spacing: 8) {
            Image(systemName: usage.id == .claude
                  ? "person.crop.circle.badge.exclamationmark"
                  : "folder.badge.questionmark")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(needsSetupTitle)
                    .font(.system(size: 11, weight: .medium))
                Text(needsSetupSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if usage.id == .claude {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude login", forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(store.t("\"claude login\" 복사", "Copy \"claude login\""))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var needsSetupTitle: String {
        switch usage.id {
        case .claude:
            return store.t("Claude Code 로그인이 필요합니다", "Claude Code login required")
        case .codex:
            return store.t("Codex 사용 기록이 없습니다", "No Codex usage found")
        case .gemini:
            return store.t("Gemini 사용 기록이 없습니다", "No Gemini usage found")
        case .cursor:
            // [SPEC-002] Q4 확정: 단일 needsSetup 문구 (미설치/미로그인 통합, 보안상 경로 미노출)
            return store.t("Cursor 로그인이 필요합니다", "Cursor login required")
        }
    }

    private var needsSetupSubtitle: String {
        switch usage.id {
        case .claude:
            return store.t("터미널에서 claude login 실행", "Run claude login in a terminal")
        case .codex:
            return store.t("~/.codex/sessions에서 최근 24시간 기록을 찾을 수 없습니다",
                           "No activity in ~/.codex/sessions in the last 24h")
        case .gemini:
            return store.t("~/.gemini/tmp에서 최근 24시간 기록을 찾을 수 없습니다",
                           "No activity in ~/.gemini/tmp in the last 24h")
        case .cursor:
            // [SPEC-002] 경로 상세 미노출 (R7.2, Q4)
            return store.t("Cursor 앱에서 로그인 후 다시 시도하세요",
                           "Sign in to the Cursor app and try again")
        }
    }

    // MARK: - error

    private func errorBody(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .accessibilityLabel(store.t("새로고침", "Refresh"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - data

    @ViewBuilder
    private var dataBody: some View {
        // 분기 결정 규칙:
        // 1. cursorPercent != nil → percentBody (Cursor, usage-summary 기반)
        // 2. isEstimate == true → estimateBody (Codex/Gemini)
        // 3. else → quotaBody (Claude)
        if let cursorPercent = usage.cursorPercent {
            percentBody(cursorPercent: cursorPercent)
        } else if usage.isEstimate {
            if let estimate = usage.estimate {
                estimateBody(estimate: estimate)
            }
        } else {
            if let quota = usage.quota {
                quotaBody(quota: quota)
            }
        }
    }

    // MARK: data — Cursor 퍼센트 쿼터 (percentBody) [SPEC-002 재설계]

    @ViewBuilder
    private func percentBody(cursorPercent: CursorPercentInfo) -> some View {
        VStack(spacing: 8) {
            // 헤더: "Cursor 쿼터" + 새로고침
            HStack {
                Text(store.t("Cursor 쿼터", "Cursor Quota"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if let membership = cursorPercent.membershipType {
                    Text(membership)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.quaternaryLabelColor))
                        .cornerRadius(4)
                }
                Spacer()
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("새로고침", "Refresh"))
            }

            // 퍼센트 행 (quotaRow 스타일 재사용)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(store.t("사용량", "Usage"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    let pct = min(100, cursorPercent.totalPercentUsed)
                    Text("\(Int(pct))% \(store.t("사용", "used"))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(barColor(pct))
                    if let resetDate = cursorPercent.billingCycleEnd {
                        Text("· \(resetLabel(resetDate))")
                            .font(.system(size: 10))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                }
                GeometryReader { geo in
                    let pct = min(100, cursorPercent.totalPercentUsed)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(NSColor.quaternaryLabelColor))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor(pct))
                            .frame(width: max(0, geo.size.width * pct / 100), height: 4)
                    }
                }
                .frame(height: 4)
            }

            // 비용 행: 항상 "비용 정보 없음" (R4.3, AC5 — $0 절대 금지)
            HStack {
                Text(store.t("비용", "Cost"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(store.t("비용 정보 없음", "Cost N/A"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cursor \(store.t("쿼터", "quota")) \(Int(min(100, cursorPercent.totalPercentUsed)))\(store.t("% 사용", "% used")), \(store.t("비용 정보 없음", "Cost N/A"))")
    }

    // MARK: data — Claude (quota)

    private func quotaBody(quota: QuotaInfo) -> some View {
        VStack(spacing: 8) {
            // 헤더
            HStack {
                Text(store.t("Claude 쿼터", "Claude Quota"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if let plan = quota.planName {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .cornerRadius(4)
                }
                Spacer()
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("새로고침", "Refresh"))
            }

            // 세션 (5시간)
            quotaRow(
                label: store.t("세션 (5h)", "Session (5h)"),
                utilization: quota.sessionUtilization,
                resetsAt: quota.sessionResetsAt
            )

            // 주간
            quotaRow(
                label: store.t("주간", "Weekly"),
                utilization: quota.weeklyUtilization,
                resetsAt: quota.weeklyResetsAt
            )

            // Extra Usage
            if let extra = quota.extra, extra.enabled {
                HStack {
                    Text(store.t("추가 사용", "Extra"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("$\(String(format: "%.2f", extra.spentDollars)) / $\(String(format: "%.0f", extra.limitDollars))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func quotaRow(label: String, utilization: Double, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(utilization))% \(store.t("사용", "used"))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(barColor(utilization))
                    .accessibilityValue("\(label) \(Int(utilization))% \(store.t("사용", "used"))")
                if let resetsAt {
                    Text("· \(resetLabel(resetsAt))")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(NSColor.quaternaryLabelColor))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(utilization))
                        .frame(width: max(0, geo.size.width * utilization / 100), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private func barColor(_ utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }

    private func resetLabel(_ date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else { return store.t("리셋 중", "resetting") }
        let h = Int(diff / 3600)
        let m = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if h >= 24 { return store.t("\(h/24)일 후", "in \(h/24)d") }
        if h > 0   { return store.t("\(h)h \(m)m 후", "in \(h)h \(m)m") }
        return store.t("\(m)m 후", "in \(m)m")
    }

    // MARK: data — Codex/Gemini (estimate)

    private func estimateBody(estimate: EstimateInfo) -> some View {
        VStack(spacing: 8) {
            // 헤더: "Codex 사용량 / Codex Usage" + EstimateBadge + 새로고침
            HStack {
                Text(usageHeaderLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                EstimateBadge(store: store)
                Spacer()
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("새로고침", "Refresh"))
            }

            // 토큰 행 (항상 표시)
            HStack {
                Text(store.t("토큰 (24h)", "Tokens (24h)"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTokens(estimate.totalTokens))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // 비용 행
            HStack {
                Text(store.t("추정 비용", "Est. cost"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if estimate.isCostUnavailable {
                    // 비용 추정 불가 ($0 절대 표시 금지, C3)
                    Text(store.t("비용 추정 불가", "Cost N/A"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                } else if let cost = estimate.costDollars {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                // totalTokens==0 && costDollars==nil: 비용 행 값 미표시
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(estimateAccessibilityLabel(estimate: estimate))
    }

    private var usageHeaderLabel: String {
        // estimateBody는 isEstimate==true일 때만 호출되므로 .claude에 도달하지 않음
        switch usage.id {
        case .codex:  return store.t("Codex 사용량", "Codex Usage")
        case .gemini: return store.t("Gemini 사용량", "Gemini Usage")
        default:      return store.t("Claude 쿼터", "Claude Quota")
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    private func estimateAccessibilityLabel(estimate: EstimateInfo) -> String {
        let provider = usage.displayName
        let tokenStr = formatTokens(estimate.totalTokens)
        if estimate.isCostUnavailable {
            return "\(provider) \(store.t("사용량, 추정, 토큰", "usage, estimate, tokens")) \(tokenStr), \(store.t("비용 추정 불가", "Cost N/A"))"
        } else if let cost = estimate.costDollars {
            return "\(provider) \(store.t("사용량, 추정, 토큰", "usage, estimate, tokens")) \(tokenStr), \(String(format: "$%.2f", cost))"
        }
        return "\(provider) \(store.t("사용량, 추정, 토큰", "usage, estimate, tokens")) \(tokenStr)"
    }

    // MARK: - disabledFallback (Gemini, R2.4)

    private var disabledFallbackBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 13))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            Text(store.t("현재 Gemini 사용량을 지원하지 않습니다", "Gemini usage is not supported yet"))
                .font(.system(size: 11))
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - EstimateBadge (추정 배지, design.md 컴포넌트 5)

struct EstimateBadge: View {
    @ObservedObject var store: AgentStore

    var body: some View {
        Text(store.t("추정", "Estimate"))
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color(NSColor.secondaryLabelColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(NSColor.quaternaryLabelColor))
            .cornerRadius(4)
            .accessibilityLabel(store.t("추정치", "Estimated"))
    }
}
