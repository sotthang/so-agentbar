import XCTest
@testable import SoAgentBar

/// 토큰 자동 갱신을 위한 순수 함수 단위 테스트.
/// 네트워크/키체인 같은 사이드이펙트 없이 검증 가능한 부분만 다룬다.
final class UsageMonitorTokenTests: XCTestCase {

    // MARK: - parseCredentials

    func test_parseCredentials_validJSON_returnsAllFields() {
        let json = """
        {"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":1781451352969},"organizationUuid":"org-1"}
        """.data(using: .utf8)!

        let creds = UsageMonitor.parseCredentials(from: json)

        XCTAssertEqual(creds?.accessToken, "AT")
        XCTAssertEqual(creds?.refreshToken, "RT")
        // 1781451352969 ms == 1781451352.969 s
        XCTAssertEqual(creds?.expiresAt, Date(timeIntervalSince1970: 1781451352.969))
    }

    func test_parseCredentials_missingAccessToken_returnsNil() {
        let json = """
        {"claudeAiOauth":{"refreshToken":"RT"}}
        """.data(using: .utf8)!
        XCTAssertNil(UsageMonitor.parseCredentials(from: json))
    }

    func test_parseCredentials_noExpiresAt_expiresAtIsNil() {
        let json = """
        {"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT"}}
        """.data(using: .utf8)!
        let creds = UsageMonitor.parseCredentials(from: json)
        XCTAssertEqual(creds?.accessToken, "AT")
        XCTAssertNil(creds?.expiresAt)
    }

    // MARK: - isTokenExpired

    func test_isTokenExpired_farFuture_returnsFalse() {
        let now = Date(timeIntervalSince1970: 1000)
        let exp = Date(timeIntervalSince1970: 1000 + 3600)  // 1시간 뒤
        XCTAssertFalse(UsageMonitor.isTokenExpired(expiresAt: exp, now: now, skew: 300))
    }

    func test_isTokenExpired_withinSkew_returnsTrue() {
        let now = Date(timeIntervalSince1970: 1000)
        let exp = Date(timeIntervalSince1970: 1000 + 100)  // 100초 뒤 (skew 300초 안쪽)
        XCTAssertTrue(UsageMonitor.isTokenExpired(expiresAt: exp, now: now, skew: 300))
    }

    func test_isTokenExpired_alreadyPast_returnsTrue() {
        let now = Date(timeIntervalSince1970: 1000)
        let exp = Date(timeIntervalSince1970: 500)  // 이미 지남
        XCTAssertTrue(UsageMonitor.isTokenExpired(expiresAt: exp, now: now, skew: 300))
    }

    func test_isTokenExpired_nilExpiresAt_returnsFalse() {
        // 만료 시각을 모르면 그대로 사용 (선제 갱신하지 않음)
        XCTAssertFalse(UsageMonitor.isTokenExpired(expiresAt: nil, now: Date(), skew: 300))
    }

    // MARK: - buildRefreshRequest

    func test_buildRefreshRequest_hasCorrectURLMethodAndHeaders() {
        let req = UsageMonitor.buildRefreshRequest(refreshToken: "RT")
        XCTAssertEqual(req.url, URL(string: "https://console.anthropic.com/v1/oauth/token"))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_buildRefreshRequest_bodyContainsGrantAndClientId() throws {
        let req = UsageMonitor.buildRefreshRequest(refreshToken: "RT")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["grant_type"], "refresh_token")
        XCTAssertEqual(json["refresh_token"], "RT")
        XCTAssertEqual(json["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    // MARK: - parseRefreshResponse

    func test_parseRefreshResponse_valid_returnsToken() {
        let json = """
        {"access_token":"NEW_AT","refresh_token":"NEW_RT","expires_in":28800}
        """.data(using: .utf8)!
        let t = UsageMonitor.parseRefreshResponse(from: json)
        XCTAssertEqual(t?.accessToken, "NEW_AT")
        XCTAssertEqual(t?.refreshToken, "NEW_RT")
        XCTAssertEqual(t?.expiresIn, 28800)
    }

    func test_parseRefreshResponse_missingAccessToken_returnsNil() {
        let json = """
        {"error":{"type":"invalid_grant"}}
        """.data(using: .utf8)!
        XCTAssertNil(UsageMonitor.parseRefreshResponse(from: json))
    }

    // MARK: - mergedCredentialsJSON

    func test_mergedCredentialsJSON_updatesTokensAndPreservesOrgUuid() throws {
        let original = """
        {"claudeAiOauth":{"accessToken":"OLD_AT","refreshToken":"OLD_RT","expiresAt":1000,"scopes":["a"]},"organizationUuid":"org-1"}
        """.data(using: .utf8)!
        let refreshed = RefreshedToken(accessToken: "NEW_AT", refreshToken: "NEW_RT", expiresIn: 100)
        let now = Date(timeIntervalSince1970: 50)

        let merged = try XCTUnwrap(UsageMonitor.mergedCredentialsJSON(original: original, refreshed: refreshed, now: now))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let oauth = try XCTUnwrap(json["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "NEW_AT")
        XCTAssertEqual(oauth["refreshToken"] as? String, "NEW_RT")
        // (50 + 100) * 1000 = 150000 ms
        XCTAssertEqual(oauth["expiresAt"] as? Double, 150000)
        // 보존되어야 하는 필드
        XCTAssertEqual(json["organizationUuid"] as? String, "org-1")
        XCTAssertEqual((oauth["scopes"] as? [String]), ["a"])
    }

    func test_mergedCredentialsJSON_nilRefreshToken_keepsOriginalRefreshToken() throws {
        let original = """
        {"claudeAiOauth":{"accessToken":"OLD_AT","refreshToken":"OLD_RT","expiresAt":1000}}
        """.data(using: .utf8)!
        let refreshed = RefreshedToken(accessToken: "NEW_AT", refreshToken: nil, expiresIn: nil)

        let merged = try XCTUnwrap(UsageMonitor.mergedCredentialsJSON(original: original, refreshed: refreshed, now: Date()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let oauth = try XCTUnwrap(json["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "NEW_AT")
        XCTAssertEqual(oauth["refreshToken"] as? String, "OLD_RT")  // 유지
    }
}
