import Foundation

enum RouterError: LocalizedError, Equatable {
    case message(String)
    case notInstalled
    case badLogin

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .notInstalled: return "The Switchyard plugin isn't on the router yet."
        case .badLogin: return "The router didn't accept that password."
        }
    }
}

/// OpenWrt's JSON-RPC endpoint (uhttpd's /ubus), the same one LuCI uses.
@MainActor
final class UbusClient {
    let host: String
    let user: String
    let pass: String
    private var sid: String?

    private static let anon = "00000000000000000000000000000000"

    init(host: String, user: String, pass: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = user
        self.pass = pass
    }

    private enum Fail: Error { case denied, status(Int), notFound }

    private func rpc(_ params: [Any], timeout: Double) async throws -> Any {
        guard let url = URL(string: "http://\(host)/ubus") else { throw RouterError.message("That router address doesn't look right.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "call", "params": params] as [String: Any])
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw RouterError.message("The router at \(host) is answering too slowly. If it stays like this, reboot it.")
        } catch {
            throw RouterError.message("Can't reach the router at \(host). Are you on its Wi-Fi? (\(error.localizedDescription))")
        }
        if (resp as? HTTPURLResponse)?.statusCode == 404 {
            throw RouterError.message("The router has no /ubus endpoint. Run the Switchyard install command on it, it turns that on.")
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouterError.message("The router answered with something that isn't JSON.")
        }
        if let e = o["error"] as? [String: Any] {
            let code = e["code"] as? Int ?? 0
            let msg = e["message"] as? String ?? "ubus error \(code)"
            if code == -32002 { throw Fail.denied }
            if msg.lowercased().contains("not found") { throw Fail.notFound }
            throw RouterError.message(msg)
        }
        guard let r = o["result"] as? [Any], let status = r.first as? Int else {
            throw RouterError.message("The router's answer was missing its result.")
        }
        if status == 6 { throw Fail.denied }
        if status == 3 || status == 4 { throw Fail.notFound }
        if status != 0 { throw Fail.status(status) }
        return r.count > 1 ? r[1] : [String: Any]()
    }

    func login() async throws {
        do {
            let r = try await rpc([Self.anon, "session", "login", ["username": user, "password": pass, "timeout": 1800]], timeout: 8)
            guard let o = r as? [String: Any], let s = o["ubus_rpc_session"] as? String else { throw RouterError.badLogin }
            sid = s
        } catch Fail.denied {
            throw RouterError.badLogin
        } catch Fail.notFound {
            throw RouterError.message("The router's session service isn't answering (rpcd).")
        } catch Fail.status(let s) {
            throw RouterError.message("Login failed (ubus \(s)).")
        }
    }

    /// Calls object.method, logging in (again) when the session is missing or has run out.
    func call(_ object: String, _ method: String, _ args: [String: Any] = [:], timeout: Double = 10) async throws -> [String: Any] {
        for attempt in 0..<2 {
            if sid == nil { try await login() }
            do {
                let r = try await rpc([sid ?? Self.anon, object, method, args], timeout: timeout)
                return r as? [String: Any] ?? [:]
            } catch Fail.denied {
                sid = nil
                if attempt == 1 { throw RouterError.message("The router refused \(object).\(method). Run the install command again, then sign in again.") }
            } catch Fail.notFound {
                if object == "switchyard" { throw RouterError.notInstalled }
                throw RouterError.message("\(object).\(method) isn't on this router.")
            } catch Fail.status(let s) {
                throw RouterError.message("\(object).\(method) failed (ubus \(s)).")
            }
        }
        throw RouterError.message("The router keeps dropping the session.")
    }
}

/// Anything that can run a switchyard method: the router directly, or through the Keystone bridge.
@MainActor
protocol SwitchyardLink: AnyObject {
    var canSetUp: Bool { get }
    func call(_ method: String, _ args: [String: Any], timeout: Double) async throws -> [String: Any]
}

extension SwitchyardLink {
    func call(_ method: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        try await call(method, args, timeout: 10)
    }
}

@MainActor
final class DirectLink: SwitchyardLink {
    let client: UbusClient
    init(_ client: UbusClient) { self.client = client }
    var canSetUp: Bool { true }

    func call(_ method: String, _ args: [String: Any], timeout: Double) async throws -> [String: Any] {
        let r = try await client.call("switchyard", method, args, timeout: timeout)
        if let e = r["error"] as? String { throw RouterError.message(e) }
        return r
    }
}

/// Signs in with the root password once, makes the router create a login that can only use Switchyard,
/// and returns that. The root password is never stored.
@MainActor
enum RouterSetup {
    struct Creds: Codable, Equatable { var host: String; var user: String; var pass: String }

    static func provision(host: String, rootPassword: String) async throws -> Creds {
        let root = UbusClient(host: host, user: "root", pass: rootPassword)
        try await root.login()
        _ = try await root.call("switchyard", "version")
        let r = try await root.call("switchyard", "setup")
        if let e = r["error"] as? String { throw RouterError.message(e) }
        guard let u = r["user"] as? String, let p = r["pass"] as? String else { throw RouterError.message("The router didn't hand out a login.") }
        // Make sure the new login works before keeping it.
        let check = UbusClient(host: host, user: u, pass: p)
        _ = try await check.call("switchyard", "version")
        return Creds(host: host, user: u, pass: p)
    }

    /// Lets a device on the upstream network (the Keystone bridge) in, and returns the router's upstream address.
    static func allow(host: String, rootPassword: String, ip: String) async throws -> String? {
        let root = UbusClient(host: host, user: "root", pass: rootPassword)
        let r = try await root.call("switchyard", "allow", ["ip": ip])
        if let e = r["error"] as? String { throw RouterError.message(e) }
        return r["host"] as? String
    }

    static let installCommand = "wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/router/install.sh | sh"
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ o: [String: Any]) throws -> T {
    let d = try JSONSerialization.data(withJSONObject: o)
    return try JSONDecoder().decode(T.self, from: d)
}
