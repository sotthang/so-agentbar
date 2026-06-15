import Foundation
import SQLite3   // 시스템 제공 libsqlite3 — 새 외부 의존성 아님 (NFR1)

/// Cursor state.vscdb(SQLite)에서 accessToken을 읽기 전용으로 로드 (SPEC-002 R2).
/// 메인 액터 분리: 함수는 nonisolated이며 Task.detached에서 호출되어 UI 스레드 블로킹 방지 (NFR4).
/// 보안: 로드된 토큰은 절대 로그/에러/UI에 출력되지 않으며 토큰 소유자(cursor.com)에만 전송된다.
enum CursorTokenStore {

    // MARK: 상수

    /// DB 상대 경로 구성 요소 (Application Support 기준)
    private static let dbPathComponents = ["Cursor", "User", "globalStorage", "state.vscdb"]
    /// ItemTable에서 accessToken을 가리키는 키 (R2.1)
    static let accessTokenKey = "cursorAuth/accessToken"

    /// 기본 DB 경로: ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
    static func defaultDatabaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dbPathComponents.reduce(appSupport) { $0.appendingPathComponent($1) }
    }

    /// state.vscdb를 SQLITE_OPEN_READONLY로 열어
    /// SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' 수행.
    /// - 파일 없음/테이블 없음/키 없음/빈 값 → nil (크래시 금지, R2.2)
    /// - value가 TEXT 또는 BLOB 어느 쪽이든 UTF-8 문자열로 안전 변환
    /// - prepared statement는 반드시 finalize, db는 반드시 close
    /// 반환된 토큰 문자열은 로그/에러에 절대 출력하지 않는다 (R7.2)
    nonisolated static func loadAccessToken(
        databaseURL: URL = CursorTokenStore.defaultDatabaseURL()
    ) -> String? {
        let path = databaseURL.path

        // 파일 존재 확인 (SQLITE_OPEN_READONLY는 파일 없으면 에러, 크래시 방지)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let query = "SELECT value FROM ItemTable WHERE key = '\(accessTokenKey)' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // value는 TEXT 또는 BLOB — 둘 다 안전 처리 (R2)
        if let cStr = sqlite3_column_text(stmt, 0) {
            let token = String(cString: cStr)
            return token.isEmpty ? nil : token
        }

        // BLOB 폴백
        if let blobPtr = sqlite3_column_blob(stmt, 0) {
            let byteCount = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blobPtr, count: byteCount)
            let token = String(data: data, encoding: .utf8) ?? ""
            return token.isEmpty ? nil : token
        }

        return nil
    }
}
