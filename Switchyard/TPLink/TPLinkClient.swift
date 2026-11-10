import Foundation

/// TP-Link Archer web API (the encrypted "luci" one the Archer AX10/AX1500 family uses).
/// Login: RSA-encrypted password, then every request is AES-CBC encrypted and RSA-signed.
/// Newer firmware (2048-bit key) drops the AES layer; that's handled too.
@MainActor
final class TPLinkClient {
    let host: String
    let password: String
    private(set) var username = "admin"

    private var stok = ""
    private var sysauth = ""
    private var seq = 0
    private var signN = ""
    private var signE = ""
    private var session = TPSession()
    private var plain = false          // firmware 1.11+: no AES layer
    private var jsonBody = false       // some firmware wants {"operation":"read"} instead of a form
    private var logged = false

    init(host: String, password: String) {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.hasPrefix("http") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        self.host = h
        self.password = password
    }

    private var hash: String { TPCrypto.md5Hex(username + password) }

    private func post(_ path: String, body: String, contentType: String = "application/x-www-form-urlencoded", timeout: Double = 10) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: host + "/cgi-bin/luci/;stok=" + path) else { throw TPError.message("That address doesn't look right.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpShouldHandleCookies = false
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(host + "/webpages/index.html", forHTTPHeaderField: "Referer")
        req.setValue(host, forHTTPHeaderField: "Origin")
        if !sysauth.isEmpty { req.setValue("sysauth=" + sysauth, forHTTPHeaderField: "Cookie") }
        req.httpBody = Data(body.utf8)
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            guard let h = r as? HTTPURLResponse else { throw TPError.message("No answer from the TP-Link.") }
            return (d, h)
        } catch let e as TPError {
            throw e
        } catch {
            throw TPError.message("Can't reach the TP-Link at \(host). Are you on its network?")
        }
    }

    private static func form(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func object(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Asks for one of the login pages. Newer firmware (travel routers like the TL-WR1502X) wants the
    /// operation only in the URL and an empty body; older Archers also take it in the body.
    private func loginPage(_ form: String) async throws -> [String: Any] {
        var last = ""
        for body in ["", "operation=read"] {
            let (d, _) = try await post("/login?form=\(form)&operation=read", body: body)
            if let o = Self.object(d), let data = o["data"] as? [String: Any] { return data }
            last = String(decoding: d.prefix(160), as: UTF8.self)
        }
        throw TPError.message("The TP-Link's login page (\(form)) answered: \(last.isEmpty ? "nothing" : last)")
    }

    private func keys() async throws {
        let data = try await loginPage("keys")
        guard let pw = data["password"] as? [String], pw.count == 2 else {
            throw TPError.message("The TP-Link didn't send its password key.")
        }
        passN = pw[0]
        passE = pw[1]
        plain = pw[0].count >= 512
        // Repeater-mode firmware reports its account name (often empty); the signature hash uses it.
        if let u = data["username"] as? String, !forceAdmin { username = u } else if forceAdmin { username = "admin" }
    }
    private var passN = ""
    private var passE = ""

    private func auth() async throws {
        let data = try await loginPage("auth")
        guard let k = data["key"] as? [String], k.count == 2 else {
            throw TPError.message("The TP-Link didn't send its signing key.")
        }
        signN = k[0]
        signE = k[1]
        seq = (data["seq"] as? Int) ?? Int("\(data["seq"] ?? "0")") ?? 0
    }

    func login() async throws {
        do {
            try await loginOnce()
        } catch let e as TPError {
            // Repeater-mode firmware reports an empty account name. If the router turns that signature
            // down for anything other than a wrong password, try once more the classic way ("admin").
            guard username.isEmpty, case .message(let m) = e, !m.hasPrefix("Wrong password"), !m.contains("refusing logins") else { throw e }
            forceAdmin = true
            try await loginOnce()
        }
    }
    private var forceAdmin = false

    private func loginOnce() async throws {
        logged = false
        stok = ""
        sysauth = ""
        session = TPSession()
        try await keys()
        let pwHex = try TPCrypto.rsaPKCS1(Array(password.utf8), nHex: passN, eHex: passE)
        let result: (Data, HTTPURLResponse)
        if plain {
            result = try await post("/login?form=login", body: "operation=login&password=\(pwHex)")
        } else {
            try await auth()
            let enc = try session.encrypt("operation=login&password=\(pwHex)&confirm=true")
            let sign = try session.sign(seq: seq + enc.count, login: true, hash: hash, nHex: signN, eHex: signE)
            result = try await post("/login?form=login", body: "sign=\(sign)&data=\(Self.form(enc))")
        }
        let (d, resp) = result
        guard var o = Self.object(d) else {
            throw TPError.message(resp.statusCode == 403 ? "The TP-Link is refusing logins for now (too many tries?). Wait a few minutes." : "The TP-Link's login answer wasn't JSON.")
        }
        if !plain, let enc = o["data"] as? String {
            o = Self.object(Data(try session.decrypt(enc).utf8)) ?? [:]
        }
        guard (o["success"] as? Bool) == true, let data = o["data"] as? [String: Any], let s = data["stok"] as? String else {
            let info = o["data"] as? [String: Any]
            if let left = info?["attemptsAllowed"] { throw TPError.message("Wrong password. \(left) tries left before it locks you out.") }
            if let code = (o["errorcode"] ?? info?["errorcode"]) { throw TPError.message("Login failed (\(code)). If the web page is open somewhere, log out there first.") }
            throw TPError.message("Login failed.")
        }
        stok = s
        if let cookie = resp.value(forHTTPHeaderField: "Set-Cookie"),
           let r = cookie.range(of: #"sysauth=([^;]+)"#, options: .regularExpression) {
            sysauth = String(cookie[r].dropFirst("sysauth=".count))
        }
        logged = true
    }

    /// One API call, e.g. request("admin/status?form=all", "operation=read").
    func request(_ path: String, _ data: String) async throws -> Any {
        for attempt in 0..<2 {
            if !logged { try await login() }
            do {
                return try await send(path, data)
            } catch TPNeedsLogin.again {
                logged = false
                if attempt == 1 { throw TPError.message("The TP-Link keeps logging Switchyard out.") }
            }
        }
        throw TPError.message("The TP-Link keeps logging Switchyard out.")
    }

    private enum TPNeedsLogin: Error { case again }

    private func send(_ path: String, _ data: String) async throws -> Any {
        let op = data.split(separator: "&").first(where: { $0.hasPrefix("operation=") }).map(String.init)
        var p = path
        if let op, !p.contains("operation=") { p += (p.contains("?") ? "&" : "?") + op }
        let payload: String
        if jsonBody {
            var dict: [String: String] = [:]
            for pair in data.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                dict[kv[0]] = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            }
            payload = String(decoding: try JSONSerialization.data(withJSONObject: dict), as: UTF8.self)
        } else {
            payload = data
        }
        let result: (Data, HTTPURLResponse)
        if plain {
            result = try await post("/" + stokPath(p), body: payload, contentType: jsonBody ? "application/json" : "application/x-www-form-urlencoded")
        } else {
            let enc = try session.encrypt(payload)
            let sign = try session.sign(seq: seq + enc.count, login: false, hash: hash, nHex: signN, eHex: signE)
            result = try await post("/" + stokPath(p), body: "sign=\(sign)&data=\(Self.form(enc))")
        }
        let (d, resp) = result
        if resp.statusCode == 401 || resp.statusCode == 403 { throw TPNeedsLogin.again }
        guard var o = Self.object(d) else {
            if d.isEmpty { return [String: Any]() }   // reboot and logout answer with nothing
            throw TPNeedsLogin.again
        }
        if !plain, let enc = o["data"] as? String {
            guard let inner = Self.object(Data(try session.decrypt(enc).utf8)) else { throw TPNeedsLogin.again }
            o = inner
        }
        if (o["success"] as? Bool) == true { return o["data"] ?? [String: Any]() }
        let code = "\(o["errorcode"] ?? "")"
        if code.contains("timeout") || code == "-40401" || code.contains("login") { throw TPNeedsLogin.again }
        if !jsonBody && !triedJSON {
            // Some firmware only takes {"operation":"read"} bodies. Try that once; keep it if it works.
            triedJSON = true
            jsonBody = true
            do {
                return try await send(path, data)
            } catch {
                jsonBody = false
                throw error
            }
        }
        throw TPError.message("The TP-Link said no (\(code.isEmpty ? "unknown error" : code)).")
    }
    private var triedJSON = false

    private func stokPath(_ p: String) -> String { stok + "/" + p }

    func logout() async {
        guard logged else { return }
        _ = try? await send("admin/system?form=logout", "operation=write")
        logged = false
    }
}

// MARK: - What Switchyard reads and changes

struct TPStatus: Equatable {
    struct Client: Equatable, Identifiable {
        var mac: String; var ip: String; var name: String; var kind: String
        var id: String { mac }
    }
    var wanIP: String?
    var wanGateway: String?
    var lanIP: String?
    var cpu: Double?
    var mem: Double?
    var connType: String?
    var wifi2g: Bool?
    var wifi5g: Bool?
    var guest2g: Bool?
    var guest5g: Bool?
    var clients: [Client] = []
}

struct TPWifi: Equatable, Identifiable {
    var form: String          // wireless_2g, wireless_5g, guest_2g, guest_5g
    var enabled: Bool?
    var ssid: String?
    var key: String?
    var hidden: Bool?
    var channel: String?
    var id: String { form }
    var title: String {
        switch form {
        case "wireless_2g": return "2.4 GHz"
        case "wireless_5g": return "5 GHz"
        case "guest_2g": return "Guest 2.4 GHz"
        case "guest_5g": return "Guest 5 GHz"
        default: return form
        }
    }
    var isGuest: Bool { form.hasPrefix("guest") }
}

struct TPFirmware: Equatable { var model: String?; var hardware: String?; var firmware: String? }

extension TPLinkClient {
    private static func on(_ v: Any?) -> Bool? {
        guard let v else { return nil }
        let s = "\(v)".lowercased()
        return s == "on" || s == "true" || s == "yes" || s == "1"
    }

    private static func str(_ v: Any?) -> String? {
        guard let v, !(v is NSNull) else { return nil }
        let s = "\(v)"
        return s.isEmpty ? nil : s
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func status() async throws -> TPStatus {
        let d = ((try? await request("admin/status?form=all", "operation=read")) as? [String: Any]) ?? [:]
        var s = TPStatus()
        s.wanIP = Self.str(d["wan_ipv4_ipaddr"])
        s.wanGateway = Self.str(d["wan_ipv4_gateway"])
        s.lanIP = Self.str(d["lan_ipv4_ipaddr"])
        s.cpu = Self.num(d["cpu_usage"])
        s.mem = Self.num(d["mem_usage"])
        s.connType = Self.str(d["conn_type"]) ?? Self.str(d["wan_ipv4_conntype"])
        s.wifi2g = Self.on(d["wireless_2g_enable"])
        s.wifi5g = Self.on(d["wireless_5g_enable"])
        s.guest2g = Self.on(d["guest_2g_enable"])
        s.guest5g = Self.on(d["guest_5g_enable"])
        func add(_ key: String, _ kind: (([String: Any]) -> String)) {
            for item in d[key] as? [[String: Any]] ?? [] {
                let mac = (Self.str(item["macaddr"]) ?? Self.str(item["mac"]) ?? "").uppercased()
                guard !mac.isEmpty, !s.clients.contains(where: { $0.mac == mac }) else { continue }
                s.clients.append(.init(mac: mac, ip: Self.str(item["ipaddr"]) ?? "", name: Self.str(item["hostname"]) ?? "", kind: kind(item)))
            }
        }
        func band(_ i: [String: Any]) -> String {
            let w = (Self.str(i["wire_type"]) ?? "").lowercased()
            if w.hasPrefix("2.4") { return "2.4 GHz" }
            if w.hasPrefix("5") { return "5 GHz" }
            if w == "wired" { return "Wired" }
            return w.isEmpty ? "Wi-Fi" : w
        }
        add("access_devices_wired") { _ in "Wired" }
        add("access_devices_wireless_host") { band($0) }
        add("access_devices_wireless_guest") { "Guest " + band($0) }
        if s.cpu == nil, let p = try? await request("admin/status?form=perf", "operation=read") as? [String: Any] {
            s.cpu = Self.num(p["cpu_usage"])
            s.mem = Self.num(p["mem_usage"])
        }
        return s
    }

    func firmware() async throws -> TPFirmware {
        let d = try await request("admin/firmware?form=upgrade", "operation=read") as? [String: Any] ?? [:]
        return TPFirmware(model: Self.str(d["model"]), hardware: Self.str(d["hardware_version"]), firmware: Self.str(d["firmware_version"]))
    }

    func wifi(_ form: String) async throws -> TPWifi {
        let d = try await request("admin/wireless?form=\(form)", "operation=read") as? [String: Any] ?? [:]
        func v(_ k: String) -> Any? { d["\(form)_\(k)"] ?? d[k] }
        return TPWifi(form: form, enabled: Self.on(v("enable")), ssid: Self.str(v("ssid")), key: Self.str(v("psk_key")),
                      hidden: Self.on(v("hidden")), channel: Self.str(v("channel")))
    }

    func setWifi(_ form: String, enable: Bool? = nil, ssid: String? = nil, key: String? = nil, hidden: Bool? = nil) async throws {
        var data = "operation=write"
        let onlyEnable = ssid == nil && key == nil && hidden == nil
        if let enable { data += onlyEnable ? "&enable=\(enable ? "on" : "off")" : "&\(form)_enable=\(enable ? "on" : "off")" }
        if let ssid { data += "&\(form)_ssid=\(Self.encode(ssid))" }
        if let key { data += "&\(form)_psk_key=\(Self.encode(key))" }
        if let hidden { data += "&\(form)_hidden=\(hidden ? "on" : "off")" }
        _ = try await request("admin/wireless?form=\(form)", data)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// The front-panel lights. Not every firmware has this page.
    func leds() async throws -> Bool? {
        let d = try await request("admin/ledgeneral?form=setting", "operation=read") as? [String: Any] ?? [:]
        return Self.on(d["enable"])
    }

    func setLeds(_ on: Bool) async throws {
        _ = try await request("admin/ledgeneral?form=setting", "operation=write&enable=\(on ? "on" : "off")")
    }

    func reboot() async throws {
        _ = try await request("admin/system?form=reboot", "operation=write")
        await logout()
    }
}

// MARK: - Diagnose: find out which pages this firmware has

extension TPLinkClient {
    private func fetchText(_ path: String) async -> String? {
        guard let url = URL(string: host + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.httpShouldHandleCookies = false
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: d.prefix(2_000_000), as: UTF8.self)
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// Reads the router's own web pages (no login needed) and lists every "admin/x?form=y" they call.
    private func discoverPages() async -> (pages: [String], files: Int) {
        var queue = ["/webpages/index.html"]
        var seen = Set<String>()
        var found = Set<String>()
        while let path = queue.first, seen.count < 80 {
            queue.removeFirst()
            guard seen.insert(path).inserted, let text = await fetchText(path) else { continue }
            for m in Self.matches(#"admin/[A-Za-z0-9_]+\?form=[A-Za-z0-9_]+"#, in: text) { found.insert(m) }
            let dir = path.hasPrefix("/webpages/") ? "/webpages/" : "/"
            for ref in Self.matches(#"[A-Za-z0-9_./-]+\.(js|html)"#, in: text) {
                guard !ref.contains("//"), !ref.hasPrefix("http") else { continue }
                var p = ref
                while p.hasPrefix("./") { p.removeFirst(2) }
                if p.hasPrefix("../") { continue }
                let full = p.hasPrefix("/") ? p : dir + p
                if full.hasPrefix("/webpages/"), !seen.contains(full), !queue.contains(full) { queue.append(full) }
            }
        }
        return (found.sorted(), seen.count)
    }

    /// One read with no retries and no login loop: what the router actually answered, decrypted.
    private func rawRead(_ path: String, _ op: String) async -> String {
        var p = path
        if !p.contains("operation=") { p += "&operation=" + op }
        do {
            let result: (Data, HTTPURLResponse)
            if plain {
                result = try await post("/" + stokPath(p), body: "operation=" + op)
            } else {
                let enc = try session.encrypt("operation=" + op)
                let sign = try session.sign(seq: seq + enc.count, login: false, hash: hash, nHex: signN, eHex: signE)
                result = try await post("/" + stokPath(p), body: "sign=\(sign)&data=\(Self.form(enc))")
            }
            let (d, r) = result
            guard var o = Self.object(d) else {
                return "HTTP \(r.statusCode), not JSON: " + String(decoding: d.prefix(120), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            }
            if !plain, let enc = o["data"] as? String {
                guard let inner = Self.object(Data((try? session.decrypt(enc))?.utf8 ?? "".utf8)) else { return "HTTP \(r.statusCode), couldn't decrypt the answer" }
                o = inner
            }
            return Self.compact(Self.redact(o))
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    private static let secretKeys = ["key", "password", "psk", "pwd", "passphrase", "secret", "token", "stok", "sysauth", "wps_pin", "pincode"]

    private static func redact(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d {
                let l = k.lowercased()
                if secretKeys.contains(where: { l.contains($0) }), !(x is [String: Any]), !(x is [Any]), "\(x)" != "" {
                    out[k] = "<redacted>"
                } else {
                    out[k] = redact(x)
                }
            }
            return out
        }
        if let a = v as? [Any] { return a.map(redact) }
        return v
    }

    private static func compact(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "\(v)" }
        let s = String(decoding: d, as: UTF8.self)
        return s.count > 2500 ? String(s.prefix(2500)) + " …(\(s.count) chars)" : s
    }

    /// Logs in, finds every page the router's web UI uses, and reads each one (read-only).
    func diagnose(progress: @escaping (String) -> Void) async -> String {
        var out: [String] = []
        out.append("TP-Link at \(host)")
        do {
            if !logged { try await login() }
            out.append("Login: OK (account name \(username.isEmpty ? "empty" : "\"\(username)\""), \(plain ? "plain" : "encrypted") requests)")
        } catch {
            out.append("Login: FAILED: \(error.localizedDescription)")
            return out.joined(separator: "\n")
        }
        progress("Reading the router's web pages…")
        let (found, files) = await discoverPages()
        out.append("Web UI files read: \(files); pages found: \(found.count)")
        let known = ["admin/status?form=all", "admin/status?form=router", "admin/status?form=internet", "admin/status?form=perf",
                     "admin/status?form=client_status", "admin/wireless?form=wireless_2g", "admin/wireless?form=wireless_5g",
                     "admin/firmware?form=upgrade", "admin/ledgeneral?form=setting", "admin/system?form=sysmode"]
        let skip = ["logout", "reboot", "reset", "restore", "backup", "factory", "login", "upgrade_fw"]
        let pages = (found + known.filter { !found.contains($0) })
            .filter { p in !skip.contains(where: { p.lowercased().contains($0) }) }
        out.append("")
        for (i, p) in pages.prefix(120).enumerated() {
            progress("Asking \(i + 1) of \(min(pages.count, 120)): \(p)")
            let r = await rawRead(p, "read")
            out.append("\(p) [read] \(r)")
            if r.contains("errorcode") || r.hasPrefix("HTTP") {
                let l = await rawRead(p, "load")
                out.append("\(p) [load] \(l)")
            }
        }
        return out.joined(separator: "\n")
    }
}
