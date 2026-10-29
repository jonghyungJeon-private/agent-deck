import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3

/// 사용자의 Chrome 로그인 상태(쿠키)를 에이전트 브라우저로 가져오기 — 사용자가 고른 사이트만, 사용자가 누를 때만.
/// 비밀번호·방문 기록은 가져오지 않는다. 사이트 목록은 쿠키 이름·도메인만 읽으므로(암호화돼 있지 않음) 키체인을 묻지 않고,
/// 가져올 때 한 번 키체인(Chrome Safe Storage)을 물어 고른 사이트의 값만 푼다. 푼 값은 메모리에만 두고 CDP 로 브라우저에 넣는다
/// (브라우저가 자기 방식으로 저장).
///
/// macOS Chrome 쿠키 형식: `<프로필>/Cookies`(SQLite) 의 `encrypted_value` = "v10" + AES-128-CBC(IV 공백 16바이트, PKCS7),
/// 키 = PBKDF2-HMAC-SHA1(키체인 "Chrome Safe Storage" 암호, "saltysalt", 1003회, 16바이트). DB 판 24 부터는
/// 푼 값 앞 32바이트가 SHA-256(host_key) 다. 시각은 1601-01-01 부터의 마이크로초.
public enum ChromeImport {
    public struct Profile: Equatable, Sendable, Identifiable {
        public var id: String { dir.lastPathComponent }
        public var dir: URL
        public var name: String
    }

    public struct Cookie: Equatable, Sendable {
        public var host: String
        public var name: String
        public var value: String
        public var path: String
        /// 1970 부터의 초. nil = 세션 쿠키
        public var expires: Double?
        public var secure: Bool
        public var httpOnly: Bool
        /// "Strict"·"Lax"·"None", 모르면 nil
        public var sameSite: String?
        /// 쿠키를 만든 출처의 scheme("Secure"·"NonSecure", 모르면 nil)·port — Chrome 이 출처별로 쿠키를 가르는 데 쓴다
        public var sourceScheme: String?
        public var sourcePort: Int?

        public init(host: String, name: String, value: String, path: String, expires: Double?, secure: Bool, httpOnly: Bool,
                    sameSite: String?, sourceScheme: String? = nil, sourcePort: Int? = nil) {
            self.host = host
            self.name = name
            self.value = value
            self.path = path
            self.expires = expires
            self.secure = secure
            self.httpOnly = httpOnly
            self.sameSite = sameSite
            self.sourceScheme = sourceScheme
            self.sourcePort = sourcePort
        }
    }

    /// 사이트(등록 도메인) 하나와 그 쿠키 수
    public struct Site: Equatable, Sendable, Identifiable {
        public var id: String
        public var count: Int
    }

    public enum ImportError: LocalizedError, Equatable {
        case noCookies(String)
        case database(String)
        case keychain(String)

        public var errorDescription: String? {
            switch self {
            case .noCookies(let profile): return "\(profile) 프로필에 쿠키 파일이 없습니다"
            case .database(let detail): return "Chrome 쿠키를 읽지 못했습니다: \(detail)"
            case .keychain(let detail): return "키체인의 Chrome Safe Storage 를 읽지 못했습니다: \(detail)"
            }
        }
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    /// Chrome 프로필들(이름은 `Local State` 의 것, 없으면 폴더 이름). 쿠키 파일이 있는 것만.
    public static func profiles(root: URL = defaultRoot) -> [Profile] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache { names[dir] = (info as? [String: Any])?["name"] as? String }
        }
        let dirs = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .filter { cookieFile(root.appendingPathComponent($0)) != nil }
            .sorted { $0 == "Default" ? true : $1 == "Default" ? false : $0.compare($1, options: .numeric) == .orderedAscending }
        return dirs.map { Profile(dir: root.appendingPathComponent($0, isDirectory: true), name: names[$0] ?? $0) }
    }

    /// 프로필의 쿠키 파일. Chrome 96 부터는 `Network/Cookies` 에 쓰고, 옮기기 전 `Cookies` 가 그대로 남아 있을 수 있다
    /// (남은 것은 더 이상 바뀌지 않는 옛 쿠키) — 그래서 `Network/Cookies` 가 있으면 늘 그것을 읽는다.
    static func cookieFile(_ profile: URL) -> URL? {
        let fm = FileManager.default
        return [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// macOS 가 Chrome 폴더 읽기를 막았나(다른 앱 데이터 보호 — 전체 디스크 접근 권한을 줘야 읽힌다). 폴더가 없으면 false.
    public static func accessBlocked(root: URL = defaultRoot) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return false
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            return posix == Int(EPERM) || posix == Int(EACCES)
        }
    }

    /// 사이트 목록(값은 풀지 않는다 — 키체인을 묻지 않음). 쿠키가 많은 순.
    public static func sites(profile: URL, now: Date = Date()) throws -> [Site] {
        let rows = try readRows(profile: profile, now: now)
        let group = SiteGroups(rows.map(\.host))
        var counts: [String: Int] = [:]
        for row in rows { counts[group.key(row.host), default: 0] += 1 }
        return counts.map { Site(id: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }

    /// 고른 사이트의 쿠키를 푼다. key = `safeStorageKey()`(또는 시험용 `deriveKey`).
    /// 만료된 것·분할(partitioned) 쿠키·풀지 못한 것은 뺀다(뺀 수를 함께 돌려준다).
    public static func cookies(profile: URL, sites: Set<String>, key: Data, now: Date = Date()) throws -> (cookies: [Cookie], skipped: Int) {
        let rows = try readRows(profile: profile, now: now)
        let group = SiteGroups(rows.map(\.host))
        var out: [Cookie] = []
        var skipped = 0
        for row in rows where sites.contains(group.key(row.host)) {
            guard let value = row.plain.isEmpty ? decrypt(row.encrypted, key: key, host: row.host) : row.plain else {
                skipped += 1
                continue
            }
            out.append(Cookie(host: row.host, name: row.name, value: value, path: row.path, expires: row.expires,
                              secure: row.secure, httpOnly: row.httpOnly, sameSite: row.sameSite,
                              sourceScheme: row.sourceScheme, sourcePort: row.sourcePort))
        }
        return (out, skipped)
    }

    /// 세션 쿠키(만료 없음)를 정한 기간 동안 유지되는 쿠키로 바꾼다 — 프로필을 복사해 새로 띄우는 브라우저(로그인 템플릿)는
    /// 이전 세션 쿠키를 되살리지 않으므로, 세션 쿠키로만 로그인하는 사이트도 새 화면에서 로그인돼 있게.
    public static func keepingSessions(_ cookies: [Cookie], for seconds: Double, now: Date = Date()) -> [Cookie] {
        cookies.map { c in
            var c = c
            if c.expires == nil { c.expires = now.timeIntervalSince1970 + seconds }
            return c
        }
    }

    /// CDP `Storage.setCookies` 의 cookies. 도메인 쿠키(".naver.com")는 domain 으로, 호스트 전용 쿠키는 url 로 넣는다
    /// (domain 을 주면 하위 도메인까지 퍼지는 쿠키가 된다).
    public static func cdpCookies(_ cookies: [Cookie]) -> [[String: Any]] {
        cookies.map { c in
            var p: [String: Any] = ["name": c.name, "value": c.value, "path": c.path, "secure": c.secure, "httpOnly": c.httpOnly]
            if c.host.hasPrefix(".") {
                p["domain"] = c.host
            } else {
                // 호스트 전용: 만든 출처의 scheme 으로(Secure 속성 없이 HTTPS 에서 만든 쿠키도 HTTPS 출처로)
                let https = c.secure || c.sourceScheme == "Secure"
                p["url"] = (https ? "https://" : "http://") + c.host + (c.path.isEmpty ? "/" : c.path)
            }
            if let expires = c.expires { p["expires"] = expires }
            if let sameSite = c.sameSite { p["sameSite"] = sameSite }
            if let scheme = c.sourceScheme { p["sourceScheme"] = scheme }
            if let port = c.sourcePort { p["sourcePort"] = port }
            return p
        }
    }

    /// 브라우저(CDP 브라우저 주소)에 쿠키를 넣는다. 브라우저가 자기 방식으로 저장한다.
    /// 한 번에 넣다가 거절되면(잘못된 쿠키 하나) 하나씩 넣어 나머지는 들어가게 한다. (넣은 수, 거절된 수)
    /// deadline: 그때가 지나면 남은 것은 넣지 않고 거절로 센다(다른 쪽 자리를 오래 막지 않게).
    public static func inject(_ cookies: [[String: Any]], into endpoint: URL, deadline: Date = .distantFuture) async throws -> (set: Int, rejected: Int) {
        let client = CDPClient(transport: try await WebSocketTransport.connect(endpoint))
        defer { client.close() }
        var set = 0, rejected = 0
        for start in stride(from: 0, to: cookies.count, by: 200) {
            let chunk = Array(cookies[start..<min(start + 200, cookies.count)])
            if Date() >= deadline {
                rejected += cookies.count - start
                break
            }
            if (try? await client.send("Storage.setCookies", ["cookies": chunk], timeout: 10)) != nil {
                set += chunk.count
                continue
            }
            for cookie in chunk {
                if Date() < deadline, (try? await client.send("Storage.setCookies", ["cookies": [cookie]], timeout: 10)) != nil {
                    set += 1
                } else {
                    rejected += 1
                }
            }
        }
        return (set, rejected)
    }

    // MARK: - 사이트 묶기

    /// 쿠키 호스트를 사이트로 묶는다. 공용 접미사 목록을 짐작하지 않고, 이 프로필에 있는 도메인 쿠키(".charancha.com")가
    /// 정한 경계를 쓴다: 호스트가 어떤 도메인 쿠키의 도메인과 같거나 그 아래면 그중 가장 위 도메인으로, 아니면 호스트 그대로.
    /// 브라우저는 공용 접미사(".co.kr"·".co.nz")에 도메인 쿠키를 두지 않으므로 서로 다른 사이트가 한 줄로 합쳐지지 않는다.
    public struct SiteGroups {
        private let domains: Set<String>

        public init(_ hosts: [String]) {
            domains = Set(hosts.filter { $0.hasPrefix(".") }.map { Self.bare($0) })
        }

        public func key(_ host: String) -> String {
            let labels = Self.bare(host).split(separator: ".").map(String.init)
            for start in labels.indices.reversed() where start < labels.count - 1 || labels.count == 1 {
                let candidate = labels[start...].joined(separator: ".")
                if domains.contains(candidate) { return candidate }
            }
            return Self.bare(host)
        }

        static func bare(_ host: String) -> String {
            host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }
    }

    // MARK: - 키·복호화

    /// 키체인에서 Chrome Safe Storage 암호를 읽어 키를 만든다. macOS 가 "AgentDeck 이 키체인의 Chrome Safe Storage 를
    /// 사용하려고 합니다" 확인 창을 띄운다(사용자가 허용해야 한다).
    public static func safeStorageKey(service: String = "Chrome Safe Storage", account: String = "Chrome") throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw ImportError.keychain(message)
        }
        return deriveKey(password: password)
    }

    public static func deriveKey(password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        _ = password.withUnsafeBytes { raw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.bindMemory(to: CChar.self).baseAddress, password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        return Data(key)
    }

    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    /// "v10"·"v11" + AES-128-CBC. 판 24 부터의 SHA-256(host) 머리를 뗀다. 풀지 못하면 nil.
    static func decrypt(_ blob: Data, key: Data, host: String) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) || blob.prefix(3) == Data("v11".utf8) else { return nil }
        guard let plain = aes(blob.dropFirst(3), key: key, operation: CCOperation(kCCDecrypt)) else { return nil }
        let hostHash = Data(SHA256.hash(data: Data(host.utf8)))
        let body = plain.count >= 32 && plain.prefix(32) == hostHash ? plain.dropFirst(32) : plain
        return String(data: Data(body), encoding: .utf8)
    }

    static func aes(_ input: Data, key: Data, operation: CCOperation) -> Data? {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outRaw in
            input.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyRaw.baseAddress, key.count, ivRaw.baseAddress, inRaw.baseAddress, input.count,
                                outRaw.baseAddress, outCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    // MARK: - 쿠키 파일 읽기

    struct Row {
        var host, name, plain, path: String
        var encrypted: Data
        var expires: Double?
        var secure, httpOnly: Bool
        var sameSite: String?
        var sourceScheme: String?
        var sourcePort: Int?
    }

    /// Chrome 이 켜져 있으면 쿠키 파일을 잠그고 계속 쓰므로 임시 폴더(나만 읽는 권한)에 복사해 읽고 바로 지운다.
    /// 복사하는 사이 파일이 바뀌었거나(크기·시각) 복사본이 온전하지 않으면 다시 복사한다(최대 3번).
    /// 만료된 영구 쿠키와 분할 쿠키(top_frame_site_key)는 건너뛴다.
    static func readRows(profile: URL, now: Date) throws -> [Row] {
        guard let source = cookieFile(profile) else { throw ImportError.noCookies(profile.lastPathComponent) }
        var lastError: Error = ImportError.database("복사하는 동안 쿠키 파일이 계속 바뀌었습니다 — Chrome 을 잠시 쉬게 한 뒤 다시 시도하세요")
        for _ in 0..<3 {
            do {
                if let rows = try readSnapshot(source, now: now) { return rows }
            } catch {
                lastError = error
            }
            usleep(300_000)
        }
        throw lastError
    }

    /// 한 번 복사해 읽는다. 복사 중 원본이 바뀌었으면 nil(다시 복사).
    private static func readSnapshot(_ source: URL, now: Date) throws -> [Row]? {
        let fm = FileManager.default
        // 세 파일 모두(없음도 하나의 상태) 복사 전후가 같아야 한다 — 복사 도중 저널이 새로 생기거나 없어지면 다시
        let paths = ["", "-wal", "-journal"].map { source.path + $0 }
        let stamp = { paths.map { path -> String in
            guard let a = try? fm.attributesOfItem(atPath: path) else { return "-" }
            return "\(a[.size] ?? 0)@\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        } }
        let copy = fm.temporaryDirectory.appendingPathComponent("agentdeck-cookies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: copy) }
        let before = stamp()
        for path in paths where fm.fileExists(atPath: path) {
            do {
                try fm.copyItem(atPath: path, toPath: copy.appendingPathComponent("Cookies" + path.dropFirst(source.path.count)).path)
            } catch where path != source.path {
                return nil // 저널이 복사하는 사이 없어졌다
            }
        }
        guard stamp() == before else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.appendingPathComponent("Cookies").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw ImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        // 복사본이 온전한가(쓰다 만 저널은 여는 순간 되돌린다)
        guard scalar(db, "PRAGMA quick_check") == "ok" else { return nil }
        let columns = Set(tableColumns(db, "cookies"))
        let optional = { (name: String, fallback: String) in columns.contains(name) ? name : fallback }
        let sql = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, is_persistent, "
            + "\(optional("top_frame_site_key", "''")), \(optional("source_scheme", "0")), \(optional("source_port", "-1")) FROM cookies"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let nowSeconds = now.timeIntervalSince1970
        var rows: [Row] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            let text = { (i: Int32) in sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
            if !text(10).isEmpty { continue } // 분할 쿠키: 특정 상위 사이트 안에서만 쓰여 옮기지 않는다
            let persistent = sqlite3_column_int(statement, 9) != 0
            let micro = sqlite3_column_int64(statement, 5)
            let expires = persistent && micro > 0 ? Double(micro) / 1_000_000 - 11_644_473_600 : nil
            if let expires, expires <= nowSeconds { continue }
            let blob: Data = {
                guard let bytes = sqlite3_column_blob(statement, 3) else { return Data() }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
            }()
            let sameSite: String? = switch sqlite3_column_int(statement, 8) {
            case 0: "None"
            case 1: "Lax"
            case 2: "Strict"
            default: nil
            }
            let sourceScheme: String? = switch sqlite3_column_int(statement, 11) {
            case 1: "NonSecure"
            case 2: "Secure"
            default: nil
            }
            let port = Int(sqlite3_column_int(statement, 12))
            rows.append(Row(host: text(0), name: text(1), plain: text(2), path: text(4).isEmpty ? "/" : text(4), encrypted: blob,
                            expires: expires, secure: sqlite3_column_int(statement, 6) != 0,
                            httpOnly: sqlite3_column_int(statement, 7) != 0, sameSite: sameSite,
                            sourceScheme: sourceScheme, sourcePort: (1...65535).contains(port) ? port : nil))
        }
        guard step == SQLITE_DONE else { throw ImportError.database(String(cString: sqlite3_errmsg(db))) }
        return rows
    }

    static func scalar(_ db: OpaquePointer?, _ sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    static func tableColumns(_ db: OpaquePointer?, _ table: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.append(String(cString: name)) }
        }
        return names
    }
}
