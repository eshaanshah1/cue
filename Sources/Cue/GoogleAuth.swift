import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum GoogleError: LocalizedError {
    case noClient, cancelled, timedOut, stateMismatch, denied(String), noRefreshToken, noCalendarAccess, needsWriteAccess, signedOut, expired, http(Int)

    var errorDescription: String? {
        switch self {
        case .noClient: return "google-oauth.json is missing from the app."
        case .cancelled: return "Sign-in was cancelled."
        case .timedOut: return "Sign-in timed out. Try again."
        case .stateMismatch: return "Sign-in response didn’t match. Try again."
        case .denied(let e): return e == "access_denied" ? "Google access wasn’t allowed." : "Google said: \(e)"
                case .noRefreshToken: return "Google didn’t return a sign-in token. Try again."
        case .noCalendarAccess: return "Cue didn’t get calendar access. Sign in again and tick the calendar box."
        case .needsWriteAccess: return "Cue needs permission to change your calendar."
        case .signedOut: return "Not signed in to Google."
        case .expired: return "Your Google sign-in expired."
        case .http(let code): return "Google returned an error (\(code))."
        }
    }
}

/// No disk cache, no cookies: Cue keeps nothing from the network on disk.
enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.urlCache = nil
        return URLSession(configuration: c)
    }()
}

struct GoogleClient: Decodable {
    let client_id: String
    let client_secret: String
}

/// OAuth for installed apps: browser sign-in, loopback redirect, PKCE.
/// The refresh token lives in the Keychain; the access token only in memory.
@MainActor
final class GoogleAuth {
    private static let scope = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly email"
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    let client: GoogleClient? = GoogleAuth.loadClient()
    private(set) var email: String?
    private var refreshToken: String?
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var server: LoopbackServer?

    var isSignedIn: Bool { refreshToken != nil }

    /// What Google actually granted. Older sign-ins only have read access.
    private(set) var grantedScopes = UserDefaults.standard.string(forKey: "googleScopes") ?? ""
    var canWrite: Bool { grantedScopes.contains("auth/calendar.events") || grantedScopes.contains("auth/calendar ") || grantedScopes.hasSuffix("auth/calendar") }

    init() {
        // Demo mode never touches the real sign-in, so it doesn't stall on a Keychain prompt.
        if !CommandLine.arguments.contains("--demo"), let saved = Keychain.read() {
            email = saved.account
            refreshToken = saved.token
        }
    }

    private static func loadClient() -> GoogleClient? {
        struct File: Decodable { let installed: GoogleClient }
        let candidates = [
            Bundle.main.url(forResource: "google-oauth", withExtension: "json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("google-oauth.json"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
                return file.installed
            }
        }
        return nil
    }

    func signIn() async throws {
        guard let client else { throw GoogleError.noClient }
        server?.finish(.failure(GoogleError.cancelled))
        let verifier = Self.randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(16)

        let server = try await LoopbackServer.start()
        self.server = server
        defer { server.stop(); if self.server === server { self.server = nil } }
        let redirect = "http://127.0.0.1:\(server.port)"

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: client.client_id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "include_granted_scopes", value: "true"),
        ]
        NSWorkspace.shared.open(auth.url!)

        let query = try await server.waitForRedirect(timeout: 300)
        guard query["state"] == state else { throw GoogleError.stateMismatch }
        if let error = query["error"] { throw GoogleError.denied(error) }
        guard let code = query["code"] else { throw GoogleError.cancelled }

        let tokens = try await tokenRequest([
            "code": code, "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        guard tokens.scope?.contains("calendar") == true else { throw GoogleError.noCalendarAccess }
        guard let refresh = tokens.refresh_token else { throw GoogleError.noRefreshToken }
        let account = tokens.id_token.flatMap(Self.email(fromIDToken:)) ?? "Google account"
        Keychain.save(account: account, token: refresh)
        refreshToken = refresh
        email = account
        accept(tokens)
    }

    func cancelSignIn() {
        server?.finish(.failure(GoogleError.cancelled))
    }

    func signOut() {
        if let token = refreshToken {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["token": token])
            Net.session.dataTask(with: req).resume()
        }
        Keychain.delete()
        refreshToken = nil
        accessToken = nil
        email = nil
        grantedScopes = ""
        UserDefaults.standard.removeObject(forKey: "googleScopes")
    }

    func validToken() async throws -> String {
        if let token = accessToken, Date() < expiry { return token }
        guard let refresh = refreshToken else { throw GoogleError.signedOut }
        do {
            let tokens = try await tokenRequest(["refresh_token": refresh, "grant_type": "refresh_token"])
            accept(tokens)
            return tokens.access_token
        } catch GoogleError.expired {
            Keychain.delete()
            refreshToken = nil
            accessToken = nil
            throw GoogleError.expired
        }
    }

    private func accept(_ t: TokenResponse) {
        if let scope = t.scope {
            grantedScopes = scope
            UserDefaults.standard.set(scope, forKey: "googleScopes")
        }
        accessToken = t.access_token
        expiry = Date().addingTimeInterval(TimeInterval(max(60, t.expires_in - 60)))
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
        let id_token: String?
        let scope: String?
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        guard let client else { throw GoogleError.noClient }
        var all = params
        all["client_id"] = client.client_id
        all["client_secret"] = client.client_secret
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(all)
        let (data, response) = try await Net.session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401, String(decoding: data, as: UTF8.self).contains("invalid_grant") {
            throw GoogleError.expired
        }
        guard status == 200 else { throw GoogleError.http(status) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func form(_ p: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }

    /// The id_token came straight from Google over TLS, so reading its payload without verifying is fine.
    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches Google's redirect after sign-in.
/// Everything runs on the main queue.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?

    private init(_ listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackServer {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        let server = LoopbackServer(listener)
        final class Once: @unchecked Sendable { var done = false }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    server.port = listener.port?.rawValue ?? 0
                    c.resume()
                case .failed(let e):
                    once.done = true
                    c.resume(throwing: e)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { server.handle($0) }
            listener.start(queue: .main)
        }
        return server
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            if let pending { c.resume(with: pending); return }
            continuation = c
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(GoogleError.timedOut))
            }
        }
    }

    func finish(_ result: Result<[String: String], Error>) {
        guard let c = continuation else {
            if pending == nil { pending = result }
            return
        }
        continuation = nil
        c.resume(with: result)
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard query["code"] != nil || query["error"] != nil else {
                Self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            Self.respond(conn, status: "200 OK", body: Self.page(success: query["code"] != nil))
            self?.finish(.success(query))
        }
    }

    private static func respond(_ conn: NWConnection, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You’re signed in to Cue" : "Cue didn’t get access"
        let body = success ? "You can close this tab. Your meetings will appear in the menu bar." : "Close this tab and try again from Cue’s menu bar."
        return """
        <!doctype html><meta charset="utf-8"><title>Cue</title>
        <style>
        :root{color-scheme:light dark}
        body{margin:0;height:100vh;display:grid;place-items:center;font:15px -apple-system,system-ui;background:Canvas;color:CanvasText}
        div{text-align:center;max-width:420px;padding:24px}
        h1{font:600 24px -apple-system,system-ui;letter-spacing:-.3px;margin:0 0 8px}
        p{margin:0;opacity:.6;line-height:1.45}
        </style>
        <div><h1>\(title)</h1><p>\(body)</p></div>
        """
    }
}

enum Keychain {
    private static let service = "com.eshaanshah.cue.google"

    static func save(account: String, token: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Cue Google sign-in",
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> (account: String, token: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let account = item[kSecAttrAccount as String] as? String else { return nil }
        return (account, String(decoding: data, as: UTF8.self))
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
