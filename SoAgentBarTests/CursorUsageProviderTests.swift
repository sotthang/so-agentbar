import XCTest
@testable import SoAgentBar

/// SPEC-002 Cursor Usage Provider — 순수 함수 단위 테스트
///
/// AC 커버리지:
///  AC1  — parseUserId(fromJWT:) 유효 JWT → userId 추출 / 오류 JWT → nil
///  AC2  — buildCookieValue / buildUsageRequest URL(/api/usage-summary)·헤더·메서드
///  AC3  — parseUsageSummaryResponse 샘플 JSON 파싱, 퍼센트 추출
///  AC4  — totalPercentUsed 추출, billingCycleEnd 파싱
///  AC5  — data 상태에서 비용 필드 없음 ($0 표시 불가 구조적 보장)
///  AC6  — tokenPresent=false → needsSetup
///  AC7  — fetchError → error 상태, 앱 크래시 없음
///  AC8  — ProviderID.cursor.displayName, 기존 rawValue/순서 불변
///  AC9  — (통합 영역, 별도)
///  AC10 — 에러 메시지에 accessToken/cookie/sub 포함 안 됨
///  AC11 — ProviderUsage 기존 init 호환 (requests/cursorPercent 기본 nil)
final class CursorUsageProviderTests: XCTestCase {

    // MARK: - AC1: parseUserId(fromJWT:)

    /// 유효한 Cursor JWT(sub=google-oauth2|user_01J...)에서 userId를 추출한다
    func test_parseUserId_validJWT_returnsSub() {
        // 더미 JWT: header.payload.signature
        // payload: {"sub":"google-oauth2|user_01JZZZZZZZZZZZZZZZZZZZZZZ","iat":1000,"exp":9999999999}
        let payloadJSON = #"{"sub":"google-oauth2|user_01JZZZZZZZZZZZZZZZZZZZZZZ","iat":1000,"exp":9999999999}"#
        let token = makeJWT(payloadJSON: payloadJSON)

        let result = CursorUsage.parseUserId(fromJWT: token)

        XCTAssertEqual(result, "google-oauth2|user_01JZZZZZZZZZZZZZZZZZZZZZZ",
                       "유효한 JWT에서 sub 클레임이 추출돼야 한다 (AC1)")
    }

    /// sub 클레임이 없는 JWT는 nil 반환
    func test_parseUserId_noSubClaim_returnsNil() {
        let payloadJSON = #"{"iat":1000,"exp":9999999999,"name":"test"}"#
        let token = makeJWT(payloadJSON: payloadJSON)

        XCTAssertNil(CursorUsage.parseUserId(fromJWT: token),
                     "sub 클레임 없으면 nil이어야 한다 (AC1)")
    }

    /// 세그먼트가 2개뿐(header.payload 없음) → nil
    func test_parseUserId_twoSegmentsOnly_returnsNil() {
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0"  // 서명 없음
        XCTAssertNil(CursorUsage.parseUserId(fromJWT: token),
                     "JWT 세그먼트가 3개 미만이면 nil이어야 한다 (AC1)")
    }

    /// 빈 문자열 → nil
    func test_parseUserId_emptyString_returnsNil() {
        XCTAssertNil(CursorUsage.parseUserId(fromJWT: ""),
                     "빈 JWT는 nil이어야 한다 (AC1)")
    }

    /// payload가 유효한 base64url이 아님 → nil
    func test_parseUserId_invalidBase64Payload_returnsNil() {
        let token = "header.!@#$%invalid_base64!@#$%.signature"
        XCTAssertNil(CursorUsage.parseUserId(fromJWT: token),
                     "유효하지 않은 base64url payload는 nil이어야 한다 (AC1)")
    }

    /// payload가 JSON이지만 sub가 숫자(문자열 아님) → nil
    func test_parseUserId_subIsNotString_returnsNil() {
        let payloadJSON = #"{"sub":12345}"#
        let token = makeJWT(payloadJSON: payloadJSON)
        XCTAssertNil(CursorUsage.parseUserId(fromJWT: token),
                     "sub가 문자열이 아니면 nil이어야 한다 (AC1)")
    }

    // MARK: - AC2: buildCookieValue

    /// <sub>::<accessToken> 형식으로 쿠키 값 생성
    func test_buildCookieValue_returnsSubColonColonToken() {
        let result = CursorUsage.buildCookieValue(sub: "google-oauth2|user_01JABC",
                                                   accessToken: "tok_dummy_123")
        XCTAssertEqual(result, "google-oauth2|user_01JABC::tok_dummy_123",
                       "쿠키 값은 <sub>::<accessToken> 형식이어야 한다 (AC2)")
    }

    /// 빈 sub + 빈 accessToken → "::""
    func test_buildCookieValue_emptyInputs_returnsDoubleColon() {
        let result = CursorUsage.buildCookieValue(sub: "", accessToken: "")
        XCTAssertEqual(result, "::",
                       "빈 값이면 :: 만 남아야 한다 (AC2)")
    }

    // MARK: - AC2: buildUsageRequest (usage-summary 엔드포인트)

    /// URL이 https://cursor.com/api/usage-summary?user=<userId> (www 아님) 이고 GET 메서드
    func test_buildUsageRequest_urlAndMethod() {
        let req = CursorUsage.buildUsageRequest(userId: "user123", cookie: "sub::tok")
        XCTAssertEqual(req.httpMethod, "GET",
                       "Cursor usage 요청은 GET이어야 한다 (AC2, R7.3)")
        let url = req.url!
        XCTAssertEqual(url.host, "cursor.com",
                       "호스트는 cursor.com이어야 한다 (www 아님, AC2)")
        XCTAssertEqual(url.path, "/api/usage-summary",
                       "경로는 /api/usage-summary여야 한다 (AC2 재설계)")
        XCTAssertTrue(url.absoluteString.contains("user=user123"),
                      "user 쿼리 파라미터가 포함돼야 한다 (AC2)")
        XCTAssertEqual(url.scheme, "https",
                       "HTTPS여야 한다 (AC2)")
    }

    /// Cookie 헤더가 WorkosCursorSessionToken=<cookie> 형식
    func test_buildUsageRequest_cookieHeader() {
        let cookie = "google-oauth2|user_01JABC::tok_dummy_999"
        let req = CursorUsage.buildUsageRequest(userId: "user_01JABC", cookie: cookie)
        let headerValue = req.value(forHTTPHeaderField: "Cookie")
        XCTAssertNotNil(headerValue, "Cookie 헤더가 설정돼야 한다 (AC2)")
        XCTAssertEqual(headerValue, "WorkosCursorSessionToken=\(cookie)",
                       "Cookie 헤더 값이 WorkosCursorSessionToken=<cookie> 형식이어야 한다 (AC2)")
    }

    /// userId에 '|' 등 특수문자가 포함될 때 percent-encoding 처리
    func test_buildUsageRequest_userIdWithPipeIsEncoded() {
        let userId = "google-oauth2|user_01JABCDEFG"
        let req = CursorUsage.buildUsageRequest(userId: userId, cookie: "sub::tok")
        let urlStr = req.url!.absoluteString
        // '|' 는 URL 쿼리에서 %7C 로 인코딩되거나 URLComponents가 처리
        XCTAssertFalse(urlStr.contains("user=google-oauth2|user_01JABCDEFG"),
                       "| 문자는 percent-encoding 처리돼야 한다 (AC2)")
        // 디코딩 후에는 원본 userId가 복원돼야 함
        let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let userItem = components.queryItems?.first(where: { $0.name == "user" })
        XCTAssertEqual(userItem?.value, userId,
                       "디코딩 후 userId가 원본과 일치해야 한다 (AC2)")
    }

    /// 도메인이 반드시 cursor.com — 다른 도메인 없음 (보안, R7.1)
    func test_buildUsageRequest_hostIsCursorDotCom() {
        let req = CursorUsage.buildUsageRequest(userId: "u1", cookie: "c")
        XCTAssertEqual(req.url?.host, "cursor.com",
                       "토큰은 cursor.com 도메인으로만 전송해야 한다 (R7.1, AC2)")
        XCTAssertNotEqual(req.url?.host, "www.cursor.com",
                          "www.cursor.com은 308 리다이렉트 — cursor.com을 직접 써야 한다 (AC2)")
    }

    // MARK: - AC3: parseUsageSummaryResponse (새 스키마)

    /// 실측 샘플 JSON 파싱 — totalPercentUsed, billingCycleEnd, membershipType 추출
    func test_parseUsageSummaryResponse_realSample_parsesCorrectly() {
        let json = """
        {
            "billingCycleStart": "2026-05-20T02:01:11.666Z",
            "billingCycleEnd": "2026-06-20T02:01:11.666Z",
            "membershipType": "free",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 0,
                    "limit": 0,
                    "remaining": 0,
                    "breakdown": {"included": 0, "bonus": 12, "total": 12},
                    "autoPercentUsed": 0,
                    "apiPercentUsed": 12,
                    "totalPercentUsed": 6
                },
                "onDemand": {"enabled": false, "used": 0, "limit": null, "remaining": null}
            }
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)

        XCTAssertNotNil(result, "유효한 JSON은 파싱 성공해야 한다 (AC3)")
        XCTAssertEqual(result?.totalPercentUsed, 6.0, accuracy: 0.01,
                       "totalPercentUsed는 6이어야 한다 (AC3)")
        XCTAssertNotNil(result?.billingCycleEnd,
                        "billingCycleEnd가 파싱돼야 한다 (AC3)")
        XCTAssertEqual(result?.membershipType, "free",
                       "membershipType은 'free'여야 한다 (AC3)")
    }

    /// totalPercentUsed가 0인 케이스
    func test_parseUsageSummaryResponse_zeroPercent_parsesCorrectly() {
        let json = """
        {
            "billingCycleEnd": "2026-06-20T02:01:11.666Z",
            "membershipType": "free",
            "individualUsage": {
                "plan": {
                    "totalPercentUsed": 0
                }
            }
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)

        XCTAssertNotNil(result, "totalPercentUsed=0이어도 파싱 성공해야 한다 (AC3)")
        XCTAssertEqual(result?.totalPercentUsed, 0.0, accuracy: 0.01,
                       "totalPercentUsed는 0이어야 한다 (AC3)")
    }

    /// totalPercentUsed가 Double(소수점)인 케이스
    func test_parseUsageSummaryResponse_doublePercent_parsesCorrectly() {
        let json = """
        {
            "billingCycleEnd": "2026-06-20T02:01:11.666Z",
            "membershipType": "pro",
            "individualUsage": {
                "plan": {
                    "totalPercentUsed": 42.7
                }
            }
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)

        XCTAssertNotNil(result, "Double totalPercentUsed도 파싱 성공해야 한다 (AC3)")
        XCTAssertEqual(result?.totalPercentUsed, 42.7, accuracy: 0.01,
                       "totalPercentUsed Double 값이 정확해야 한다 (AC3)")
        XCTAssertEqual(result?.membershipType, "pro")
    }

    /// individualUsage 없음 → nil
    func test_parseUsageSummaryResponse_missingIndividualUsage_returnsNil() {
        let json = """
        {
            "billingCycleEnd": "2026-06-20T02:01:11.666Z",
            "membershipType": "free"
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)
        XCTAssertNil(result, "individualUsage 없으면 nil이어야 한다 (AC3)")
    }

    /// plan.totalPercentUsed 없음 → nil
    func test_parseUsageSummaryResponse_missingTotalPercentUsed_returnsNil() {
        let json = """
        {
            "billingCycleEnd": "2026-06-20T02:01:11.666Z",
            "membershipType": "free",
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 0
                }
            }
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)
        XCTAssertNil(result, "totalPercentUsed 없으면 nil이어야 한다 (AC3)")
    }

    /// 깨진 JSON → nil (크래시 없음)
    func test_parseUsageSummaryResponse_brokenJSON_returnsNil() {
        let json = "not valid json at all {{{".data(using: .utf8)!
        let result = CursorUsage.parseUsageSummaryResponse(from: json)
        XCTAssertNil(result, "깨진 JSON은 nil이어야 한다 (AC3)")
    }

    /// 빈 Data → nil
    func test_parseUsageSummaryResponse_emptyData_returnsNil() {
        let result = CursorUsage.parseUsageSummaryResponse(from: Data())
        XCTAssertNil(result, "빈 데이터는 nil이어야 한다 (AC3)")
    }

    // MARK: - AC4: billingCycleEnd 파싱

    /// billingCycleEnd ISO8601 파싱 정확성
    func test_parseUsageSummaryResponse_billingCycleEnd_parsedCorrectly() {
        let json = """
        {
            "billingCycleEnd": "2026-06-20T02:01:11.666Z",
            "membershipType": "free",
            "individualUsage": {
                "plan": {"totalPercentUsed": 10}
            }
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)

        XCTAssertNotNil(result?.billingCycleEnd, "billingCycleEnd가 파싱돼야 한다 (AC4)")
        // 2026-06-20T02:01:11.666Z 확인
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: result!.billingCycleEnd!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 20)
    }

    /// billingCycleEnd 없어도 파싱 성공 (옵셔널)
    func test_parseUsageSummaryResponse_missingBillingCycleEnd_stillSucceeds() {
        let json = """
        {
            "membershipType": "free",
            "individualUsage": {
                "plan": {"totalPercentUsed": 5}
            }
        }
        """.data(using: .utf8)!

        let result = CursorUsage.parseUsageSummaryResponse(from: json)

        XCTAssertNotNil(result, "billingCycleEnd 없어도 파싱 성공해야 한다 (AC4)")
        XCTAssertNil(result?.billingCycleEnd, "billingCycleEnd 없으면 nil이어야 한다 (AC4)")
    }

    // MARK: - AC4: toProviderUsage(summaryResponse:) — 퍼센트 매핑

    /// 정상 응답 → data 상태 + cursorPercent 설정
    func test_toProviderUsage_summaryResponse_dataState_hasPercentInfo() {
        let response = CursorUsageSummaryResponse(
            totalPercentUsed: 6.0,
            billingCycleEnd: Date(timeIntervalSince1970: 9999),
            membershipType: "free"
        )

        let usage = CursorUsage.toProviderUsage(
            summaryResponse: response,
            tokenPresent: true,
            fetchError: nil,
            now: Date()
        )

        XCTAssertEqual(usage.state, .data, "정상 응답은 data 상태여야 한다 (AC4)")
        XCTAssertNotNil(usage.cursorPercent, "cursorPercent 필드가 채워져야 한다 (AC4)")
        XCTAssertEqual(usage.cursorPercent?.totalPercentUsed, 6.0, accuracy: 0.01,
                       "totalPercentUsed가 정확해야 한다 (AC4)")
        XCTAssertNotNil(usage.cursorPercent?.billingCycleEnd,
                        "billingCycleEnd가 전달돼야 한다 (AC4)")
        XCTAssertEqual(usage.cursorPercent?.membershipType, "free",
                       "membershipType이 전달돼야 한다 (AC4)")
    }

    // MARK: - AC5: 비용 없음 구조적 보장

    /// Cursor data 상태에서 estimate(비용) 필드는 nil — $0 표시 구조적 불가
    func test_toProviderUsage_summaryResponse_dataState_estimateIsNil() {
        let response = CursorUsageSummaryResponse(
            totalPercentUsed: 5.0,
            billingCycleEnd: nil,
            membershipType: "free"
        )

        let usage = CursorUsage.toProviderUsage(
            summaryResponse: response,
            tokenPresent: true,
            fetchError: nil,
            now: Date()
        )

        XCTAssertNil(usage.estimate,
                     "Cursor data 상태에서 estimate는 nil이어야 한다 — $0 표시 불가 (AC5, R4.3)")
        XCTAssertFalse(usage.isEstimate,
                       "Cursor는 정확치이므로 isEstimate=false여야 한다 (AC5)")
    }

    // MARK: - AC6: tokenPresent=false → needsSetup

    /// 토큰 없음 → needsSetup 상태
    func test_toProviderUsage_summaryResponse_tokenAbsent_returnsNeedsSetup() {
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: false,
            fetchError: nil,
            now: Date()
        )

        XCTAssertEqual(usage.state, .needsSetup,
                       "토큰 없으면 needsSetup 상태여야 한다 (AC6, R6.1)")
        XCTAssertEqual(usage.id, .cursor, "id는 .cursor여야 한다 (AC6)")
    }

    // MARK: - AC7: fetchError → error 상태

    /// HTTP 403 → error 상태
    func test_toProviderUsage_summaryResponse_http403_returnsError() {
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: true,
            fetchError: .http(403),
            now: Date()
        )

        if case .error = usage.state {
            // 통과
        } else {
            XCTFail("HTTP 403은 error 상태여야 한다 (AC7)")
        }
    }

    /// parse 오류 → error 상태
    func test_toProviderUsage_summaryResponse_parseError_returnsError() {
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: true,
            fetchError: .parse,
            now: Date()
        )

        if case .error = usage.state {
            // 통과
        } else {
            XCTFail("파싱 오류는 error 상태여야 한다 (AC7)")
        }
    }

    /// transport 오류 → error 상태
    func test_toProviderUsage_summaryResponse_transportError_returnsError() {
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: true,
            fetchError: .transport,
            now: Date()
        )

        if case .error = usage.state {
            // 통과
        } else {
            XCTFail("transport 오류는 error 상태여야 한다 (AC7)")
        }
    }

    // MARK: - AC8: ProviderID.cursor.displayName

    /// cursor displayName == "Cursor"
    func test_providerID_cursor_displayName() {
        XCTAssertEqual(ProviderID.cursor.displayName, "Cursor",
                       "ProviderID.cursor.displayName은 \"Cursor\"여야 한다 (AC8)")
    }

    /// 기존 rawValue 불변
    func test_providerID_existingRawValues_unchanged() {
        XCTAssertEqual(ProviderID.claude.rawValue, "claude", "claude rawValue 불변 (AC8)")
        XCTAssertEqual(ProviderID.codex.rawValue, "codex", "codex rawValue 불변 (AC8)")
        XCTAssertEqual(ProviderID.gemini.rawValue, "gemini", "gemini rawValue 불변 (AC8)")
        XCTAssertEqual(ProviderID.cursor.rawValue, "cursor", "cursor rawValue (AC8)")
    }

    /// cursor는 allCases 마지막에 위치 (claude/codex/gemini 순서 불변)
    func test_providerID_cursorIsLast_existingOrderUnchanged() {
        let all = ProviderID.allCases
        XCTAssertEqual(all.first, .claude, "첫 번째는 claude여야 한다 (AC8)")
        XCTAssertEqual(all[1], .codex, "두 번째는 codex여야 한다 (AC8)")
        XCTAssertEqual(all[2], .gemini, "세 번째는 gemini여야 한다 (AC8)")
        XCTAssertEqual(all.last, .cursor, "cursor는 마지막이어야 한다 (AC8)")
    }

    // MARK: - AC10: 에러 메시지에 민감값 미포함 (보안)

    /// fetchError .http → error 메시지에 accessToken 미포함
    func test_toProviderUsage_summaryResponse_errorMessage_doesNotContainAccessToken() {
        let secretToken = "secret_access_token_abc123_xyz789"
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: true,
            fetchError: .http(403),
            now: Date()
        )

        if case .error(let msg) = usage.state {
            XCTAssertFalse(msg.contains(secretToken),
                           "에러 메시지에 accessToken이 포함되면 안 된다 (AC10, R7.2)")
        }
    }

    /// fetchError .http → error 메시지에 sub(userId) 미포함
    func test_toProviderUsage_summaryResponse_errorMessage_doesNotContainSub() {
        let secretSub = "google-oauth2|user_01JSECRETVALUE"
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: true,
            fetchError: .http(401),
            now: Date()
        )

        if case .error(let msg) = usage.state {
            XCTAssertFalse(msg.contains(secretSub),
                           "에러 메시지에 userId(sub)가 포함되면 안 된다 (AC10, R7.2)")
            XCTAssertFalse(msg.contains("google-oauth2"),
                           "에러 메시지에 OAuth 식별자가 포함되면 안 된다 (AC10)")
        }
    }

    /// transport 에러 메시지에도 민감값 없음
    func test_toProviderUsage_summaryResponse_transportError_messageIsSafe() {
        let usage = CursorUsage.toProviderUsage(
            summaryResponse: nil,
            tokenPresent: true,
            fetchError: .transport,
            now: Date()
        )

        if case .error(let msg) = usage.state {
            XCTAssertFalse(msg.contains("token"),
                           "에러 메시지에 'token' 문자열이 포함되면 안 된다 (AC10)")
            XCTAssertFalse(msg.contains("cookie"),
                           "에러 메시지에 'cookie' 문자열이 포함되면 안 된다 (AC10)")
            XCTAssertFalse(msg.isEmpty, "에러 메시지는 빈 문자열이면 안 된다")
        }
    }

    // MARK: - buildUsageSuffix cursor 분기 (퍼센트 방식, 재설계)

    /// cursor + totalPercentUsed > 0 → "N%"
    func test_buildUsageSuffix_cursor_withPercent_returnsPercentString() {
        let cursorPercent = CursorPercentInfo(
            totalPercentUsed: 6.0,
            billingCycleEnd: nil,
            membershipType: "free"
        )
        let usage = ProviderUsage(id: .cursor, state: .data, isEstimate: false,
                                  quota: nil, estimate: nil,
                                  cursorPercent: cursorPercent)

        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)

        XCTAssertEqual(result, "6%",
                       "cursor totalPercentUsed=6 → '6%' 형식이어야 한다")
    }

    /// cursor + totalPercentUsed 소수점 → 정수 변환
    func test_buildUsageSuffix_cursor_fractionalPercent_truncated() {
        let cursorPercent = CursorPercentInfo(
            totalPercentUsed: 42.7,
            billingCycleEnd: nil,
            membershipType: nil
        )
        let usage = ProviderUsage(id: .cursor, state: .data, isEstimate: false,
                                  quota: nil, estimate: nil,
                                  cursorPercent: cursorPercent)

        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)

        XCTAssertEqual(result, "42%",
                       "소수점은 정수로 변환(버림)돼야 한다")
    }

    /// cursor + totalPercentUsed == 0 → ""
    func test_buildUsageSuffix_cursor_zeroPercent_returnsEmpty() {
        let cursorPercent = CursorPercentInfo(
            totalPercentUsed: 0.0,
            billingCycleEnd: nil,
            membershipType: nil
        )
        let usage = ProviderUsage(id: .cursor, state: .data, isEstimate: false,
                                  quota: nil, estimate: nil,
                                  cursorPercent: cursorPercent)

        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)

        XCTAssertEqual(result, "",
                       "totalPercentUsed=0이면 빈 문자열이어야 한다")
    }

    /// cursor + cursorPercent nil → ""
    func test_buildUsageSuffix_cursor_percentNil_returnsEmpty() {
        let usage = ProviderUsage(id: .cursor, state: .data, isEstimate: false,
                                  quota: nil, estimate: nil,
                                  cursorPercent: nil)

        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)

        XCTAssertEqual(result, "",
                       "cursorPercent nil이면 빈 문자열이어야 한다")
    }

    /// cursor suffix는 7자 이내
    func test_buildUsageSuffix_cursor_suffixIsShort() {
        let cursorPercent = CursorPercentInfo(
            totalPercentUsed: 100.0,
            billingCycleEnd: nil,
            membershipType: nil
        )
        let usage = ProviderUsage(id: .cursor, state: .data, isEstimate: false,
                                  quota: nil, estimate: nil,
                                  cursorPercent: cursorPercent)

        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)

        XCTAssertLessThanOrEqual(result.count, 7,
                                 "메뉴바 suffix는 7자 이내여야 한다 (예: '100%')")
    }

    // MARK: - AC11: 기존 ProviderUsage 호환성 회귀 방지

    /// 기존 ProviderUsage(id:state:isEstimate:quota:estimate:) 호출이 컴파일되고 cursorPercent는 nil
    func test_providerUsage_legacyInit_percentDefaultNil() {
        let usage = ProviderUsage(id: .codex, state: .data, isEstimate: true,
                                  quota: nil,
                                  estimate: EstimateInfo(totalTokens: 1000, costDollars: 2.0, windowHours: 24))
        XCTAssertNil(usage.cursorPercent,
                     "기존 init에서 cursorPercent는 nil이어야 한다 (AC11, 회귀 방지)")
    }

    /// 기존 Codex suffix 테스트가 여전히 동작 (회귀 방지)
    func test_buildUsageSuffix_codex_regression_withCost() {
        let usage = ProviderUsage(id: .codex, state: .data, isEstimate: true,
                                  quota: nil,
                                  estimate: EstimateInfo(totalTokens: 10000, costDollars: 2.3, windowHours: 24))
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        XCTAssertEqual(result, "~$2.3", "Codex 회귀: 비용 있음 suffix 불변 (AC11)")
    }

    /// 기존 Claude suffix 테스트 회귀 방지
    func test_buildUsageSuffix_claude_regression() {
        let quota = QuotaInfo(sessionUtilization: 45, sessionResetsAt: nil,
                              weeklyUtilization: 72, weeklyResetsAt: nil,
                              planName: nil, extra: nil)
        let usage = ProviderUsage(id: .claude, state: .data, isEstimate: false,
                                  quota: quota, estimate: nil)
        let result = AppDelegate.buildUsageSuffix(usage: usage, mode: .quotaSession)
        XCTAssertEqual(result, "S45%", "Claude 회귀: quotaSession suffix 불변 (AC11)")
    }

    // MARK: - 헬퍼

    /// 더미 JWT 생성 (서명검증 안 함 — payload base64url 인코딩만)
    private func makeJWT(payloadJSON: String) -> String {
        let header = base64urlEncode(#"{"alg":"HS256","typ":"JWT"}"#)
        let payload = base64urlEncode(payloadJSON)
        let signature = "dummy_signature_not_verified"
        return "\(header).\(payload).\(signature)"
    }

    private func base64urlEncode(_ string: String) -> String {
        let data = string.data(using: .utf8)!
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
