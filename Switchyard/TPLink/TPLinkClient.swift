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

    /// The account name typed at setup, if any. It always wins over what the router reports.
    let fixedUsername: String?

    init(host: String, password: String, username: String? = nil) {
        let u = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fixedUsername = u.isEmpty ? nil : u
        if let f = fixedUsername { self.username = f }
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
        if !sysauth.isEmpty { req.setValue(sysauth, forHTTPHeaderField: "Cookie") }
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
        reportedName = data["username"] as? String
        mode = data["mode"] as? String
        if let o = override { username = o }
        else if forceAdmin { username = "admin" }
        else { username = reportedName ?? "admin" }
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

    /// Logs in and checks the session can actually read pages. The account name that goes into the
    /// request signature differs by firmware (empty in repeater mode, "admin" on Archers, or one you set),
    /// so each is tried until one gives a working session; the one that works is remembered.
    func login() async throws {
        if let good = workingName {
            override = good
            try await loginOnce()
            if await sessionWorks() { return }
            workingName = nil
        }
        // Keep logins few: TP-Links lock you out after a handful of tries. The name the router reports
        // ("admin" when it reports none), then a typed one if any.
        var names: [String?] = [nil]
        if let f = fixedUsername { names.append(f) }
        var notes: [String] = []
        // Newer firmware (certified builds, 2025 travel routers) signs with SHA-256, OAEP and HMAC
        // instead of MD5 and plain RSA. Ask the router; if it doesn't say, try both.
        let certified = await isCertifiedFirmware()
        for scheme in (certified ? [true, false] : [false, true]) {
            sg = scheme
            var used = Set<String>()
            for n in names {
                if let n, used.contains(n) { continue }
                override = n
                let label = scheme ? "newer signing" : "classic signing"
                do {
                    try await loginOnce()
                    if used.contains(username) { continue }
                    used.insert(username)
                    if await sessionWorks() { workingName = username; return }
                    notes.append("\(label), name \"\(username)\": signed in, but the session can't read anything")
                } catch {
                    let name = n ?? username
                    used.insert(name)
                    if case TPError.message(let m) = error, m.hasPrefix("Wrong password") || m.contains("refusing") { throw error }
                    notes.append("\(label), name \"\(name)\": \(error.localizedDescription)")
                }
            }
        }
        logged = false
        throw TPError.message("The TP-Link took the password but gave no working session. " + notes.joined(separator: "; "))
    }
    private var override: String?
    /// Newer TP-Link signing (SHA-256 + OAEP login, HMAC-SHA256 requests).
    private(set) var sg = false

    private func isCertifiedFirmware() async -> Bool {
        guard let (d, _) = try? await post("/device_config?form=config", body: "operation=read"),
              let o = Self.object(d), let data = o["data"] as? [String: Any],
              let certs = data["certification"] as? [String] else { return false }
        return certs.contains { $0.contains("SG CLS L1") || $0.contains("CE RED") }
    }

    private func requestSign(_ enc: String) throws -> String {
        if sg { return session.sgRequestSign(seq: seq + enc.count, hash: TPCrypto.sha256Hex(enc)) }
        return try session.sign(seq: seq + enc.count, login: false, hash: hash, nHex: signN, eHex: signE)
    }
    private var lastLoginHeaders = "(none yet)"
    private var workingName: String?
    private(set) var reportedName: String?
    private(set) var mode: String?
    var isRepeater: Bool { mode == "repeater" }

    /// Archers want operation=… in the URL too; the TL-WR1502X's own page sends it only inside the
    /// encrypted body. Try both and keep whichever this router answers.
    private func sessionWorks() async -> Bool {
        for style in [opInURL, !opInURL] {
            opInURL = style
            for p in ["admin/status?form=internet", "admin/firmware?form=upgrade", "admin/status?form=all"] {
                if (try? await send(p, "operation=read")) != nil { return true }
            }
        }
        return false
    }
    private var opInURL = true
    private var forceAdmin = false

    private func loginOnce() async throws {
        logged = false
        stok = ""
        sysauth = ""
        session = TPSession(digits: sg)
        try await keys()
        let pwHex = try TPCrypto.rsaPKCS1(Array(password.utf8), nHex: passN, eHex: passE)
        let result: (Data, HTTPURLResponse)
        if plain {
            result = try await post("/login?form=login", body: "operation=login&password=\(pwHex)")
        } else {
            try await auth()
            let enc = try session.encrypt("operation=login&password=\(pwHex)&confirm=true")
            let sign = sg
                ? try session.sgLoginSign(seq: seq + enc.count, hash: TPCrypto.sha256Hex(username + password), nHex: signN, eHex: signE)
                : try session.sign(seq: seq + enc.count, login: true, hash: hash, nHex: signN, eHex: signE)
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
        lastLoginHeaders = resp.allHeaderFields.map { k, v in
            let key = "\(k)"
            return key.lowercased() == "set-cookie" ? "\(key): " + "\(v)".replacingOccurrences(of: #"=[^;,]+"#, with: "=<redacted>", options: .regularExpression) : "\(key): \(v)"
        }.sorted().joined(separator: " | ")
        // Send back every cookie the login set (the session cookie isn't always called "sysauth").
        if let url = resp.url {
            let fields = resp.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !cookies.isEmpty { sysauth = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
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
        if opInURL, let op, !p.contains("operation=") { p += (p.contains("?") ? "&" : "?") + op }
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
            let sign = try requestSign(enc)
            result = try await post("/" + stokPath(p), body: "sign=\(sign)&data=\(Self.form(enc))")
        }
        let (d, resp) = result
        if resp.statusCode == 401 || resp.statusCode == 403 { throw TPNeedsLogin.again }
        // A missing page (404) isn't a lost session: don't log in again for it.
        if resp.statusCode == 404 { throw TPError.message("This TP-Link doesn't have that page (\(path)).") }
        var bare: [String: Any]?
        if Self.object(d) == nil, !plain, !d.isEmpty,
           let dec = try? session.decrypt(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) {
            bare = Self.object(Data(dec.utf8))   // some firmware answers with the bare encrypted text
        }
        guard var o = bare ?? Self.object(d) else {
            if d.isEmpty { return [String: Any]() }   // reboot and logout answer with nothing
            throw TPNeedsLogin.again
        }
        if bare == nil, !plain, let enc = o["data"] as? String {
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
        var signal: Int? = nil
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
    // Repeater mode
    var internet: String?
    var upstreamSSID: String?
    var upstreamBand: String?
    var upstreamSignal: Int?
    var channel2g: String?
    var channel5g: String?
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
        case "ext_2g": return "Extended 2.4 GHz"
        case "ext_5g": return "Extended 5 GHz"
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
        if !logged { try await login() }
        if isRepeater { return try await repeaterStatus() }
        var d: [String: Any] = [:]
        var firstError: Error?
        do { d = (try await request("admin/status?form=all", "operation=read")) as? [String: Any] ?? [:] }
        catch { firstError = error }
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
        // Nothing readable at all: say why instead of showing an empty dashboard.
        if let firstError, d.isEmpty, s.cpu == nil { throw firstError }
        return s
    }

    /// Travel routers in repeater/extender mode (TL-WR1502X): what they're connected to, what they
    /// broadcast, and who's on them. Page names come from the router's own web interface.
    private func repeaterStatus() async throws -> TPStatus {
        var s = TPStatus()
        let net = try await request("admin/status?form=internet", "operation=read") as? [String: Any] ?? [:]
        s.internet = Self.str(net["internet_status"])
        if let up = try? await request("admin/status?form=rootap", "operation=read") as? [String: Any] {
            let band = Self.on(up["enable_5g"]) == true ? "5g" : "2g"
            s.upstreamSSID = Self.str(up["ssid_\(band)"])
            s.upstreamBand = band == "5g" ? "5 GHz" : "2.4 GHz"
            s.upstreamSignal = Self.num(up["signal_\(band)"]).map { Int($0) }
        }
        if let r = try? await request("admin/status?form=repeater", "operation=read") as? [String: Any] {
            s.lanIP = Self.str(r["wired_ip"])
            s.wifi2g = Self.on(r["enable_2g"])
            s.wifi5g = Self.on(r["enable_5g"])
            s.channel2g = Self.str(r["channel_2g"])
            s.channel5g = Self.str(r["channel_5g"])
        }
        var list: [[String: Any]] = []
        for op in ["loadDevice", "read", "load"] {
            if let l = try? await request("admin/smart_network?form=game_accelerator", "operation=\(op)") as? [[String: Any]] { list = l; break }
        }
        for c in list {
            let mac = (Self.str(c["mac"]) ?? "").uppercased()
            guard !mac.isEmpty, !s.clients.contains(where: { $0.mac == mac }) else { continue }
            let tag = Self.str(c["deviceTag"]) ?? ""
            let kind = tag == "5G" ? "5 GHz" : tag == "2.4G" ? "2.4 GHz" : (tag.isEmpty ? "Wi-Fi" : tag)
            var client = TPStatus.Client(mac: mac, ip: Self.str(c["ip"]) ?? "", name: Self.str(c["deviceName"]) ?? "",
                                         kind: (c["isGuest"] as? Bool) == true ? "Guest " + kind : kind)
            client.signal = Self.num(c["signal"]).map { Int($0) }
            s.clients.append(client)
        }
        return s
    }

    func firmware() async throws -> TPFirmware {
        let d = try await request("admin/firmware?form=upgrade", "operation=read") as? [String: Any] ?? [:]
        return TPFirmware(model: Self.str(d["model"]), hardware: Self.str(d["hardware_version"]), firmware: Self.str(d["firmware_version"]))
    }

    func wifi(_ form: String) async throws -> TPWifi {
        if form.hasPrefix("ext_") {
            let band = String(form.dropFirst(4))
            let d = try await request("admin/wireless?form=wireless_extended_network", "operation=read") as? [String: Any] ?? [:]
            func v(_ k: String) -> Any? { d["\(k)_\(band)"] }
            return TPWifi(form: form, enabled: Self.on(v("enable")), ssid: Self.str(v("ssid")), key: Self.str(v("psk_key")),
                          hidden: Self.on(v("hidden")), channel: nil)
        }
        let d = try await request("admin/wireless?form=\(form)", "operation=read") as? [String: Any] ?? [:]
        func v(_ k: String) -> Any? { d["\(form)_\(k)"] ?? d[k] }
        return TPWifi(form: form, enabled: Self.on(v("enable")), ssid: Self.str(v("ssid")), key: Self.str(v("psk_key")),
                      hidden: Self.on(v("hidden")), channel: Self.str(v("channel")))
    }

    func setWifi(_ form: String, enable: Bool? = nil, ssid: String? = nil, key: String? = nil, hidden: Bool? = nil) async throws {
        if form.hasPrefix("ext_") {
            let band = String(form.dropFirst(4))
            var data = "operation=write"
            if let enable { data += "&enable_\(band)=\(enable ? "on" : "off")" }
            if let ssid { data += "&ssid_\(band)=\(Self.encode(ssid))" }
            if let key { data += "&psk_key_\(band)=\(Self.encode(key))" }
            if let hidden { data += "&hidden_\(band)=\(hidden ? "on" : "off")" }
            _ = try await request("admin/wireless?form=wireless_extended_network", data)
            return
        }
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
        fetched = []
        Self.sourceStore = [:]
        while let path = queue.first, seen.count < 120 {
            queue.removeFirst()
            guard seen.insert(path).inserted, let text = await fetchText(path) else { continue }
            for m in Self.matches(#"admin/[A-Za-z0-9_]+\?form=[A-Za-z0-9_]+"#, in: text) { found.insert(m) }
            for ref in Self.matches(#"[A-Za-z0-9_./-]+\.(js|html)"#, in: text) {
                guard !ref.contains("//"), !ref.hasPrefix("http") else { continue }
                var cands: [String] = []
                if let u = URL(string: ref, relativeTo: URL(string: "http://x" + path)) { cands.append(u.path) }
                if !ref.hasPrefix("/"), !ref.hasPrefix(".") { cands.append("/webpages/" + ref) }
                for full in cands where full.hasPrefix("/webpages/") && !seen.contains(full) && !queue.contains(full) {
                    queue.append(full)
                }
            }
            if text.count > 0 { fetched.append("\(path) (\(text.count) chars)") }
            if path.hasSuffix("index.html") || text.contains("cgi-bin") || text.contains("stok") || text.contains("luci")
                || text.contains("encrypt") || text.contains("sign") {
                Self.sourceStore[path] = text
            }
        }
        return (found.sorted(), seen.count)
    }

    /// Every web UI file the last discovery could actually read.
    private var fetched: [String] {
        get { Self.fetchedStore[host] ?? [] }
        set { Self.fetchedStore[host] = newValue }
    }
    private static var fetchedStore: [String: [String]] = [:]
    private static var sourceStore: [String: String] = [:]

    /// One call with no retries and no login loop: what the router actually answered, decrypted.
    /// opInURL: put operation=… in the query; bodyOp: also put it in the (encrypted) body; json: body as JSON.
    private func rawCall(_ path: String, op: String, opInURL: Bool = true, bodyOp: Bool = true, json: Bool = false, rawBody: String? = nil) async -> String {
        var p = path
        if opInURL, !p.contains("operation=") { p += (p.contains("?") ? "&" : "?") + "operation=" + op }
        let body = rawBody ?? (bodyOp ? (json ? "{\"operation\":\"\(op)\"}" : "operation=" + op) : "")
        do {
            let result: (Data, HTTPURLResponse)
            if plain {
                result = try await post("/" + stokPath(p), body: body, contentType: json ? "application/json" : "application/x-www-form-urlencoded")
            } else if body.isEmpty {
                let sign = sg ? session.sgRequestSign(seq: seq, hash: TPCrypto.sha256Hex(""))
                              : try session.sign(seq: seq, login: false, hash: hash, nHex: signN, eHex: signE)
                result = try await post("/" + stokPath(p), body: "sign=\(sign)&data=")
            } else {
                let enc = try session.encrypt(body)
                let sign = try requestSign(enc)
                result = try await post("/" + stokPath(p), body: "sign=\(sign)&data=\(Self.form(enc))")
            }
            let (d, r) = result
            let text = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if var o = Self.object(d) {
                if !plain, let enc = o["data"] as? String {
                    guard let inner = Self.object(Data(((try? session.decrypt(enc)) ?? "").utf8)) else { return "HTTP \(r.statusCode), couldn't decrypt the data field" }
                    o = inner
                }
                return "HTTP \(r.statusCode) " + Self.compact(Self.redact(o))
            }
            // Some firmware answers with the bare encrypted text, no JSON around it.
            if !text.isEmpty, let dec = try? session.decrypt(text) {
                if let o = Self.object(Data(dec.utf8)) { return "HTTP \(r.statusCode) (bare encrypted) " + Self.compact(Self.redact(o)) }
                return "HTTP \(r.statusCode) (bare encrypted, not JSON) " + String(dec.prefix(200))
            }
            return "HTTP \(r.statusCode), not JSON: " + String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    private func rawCallNoStok(_ path: String) async -> String {
        let saved = stok
        stok = ""
        defer { stok = saved }
        return await rawCall(path, op: "read")
    }

    /// Lines of the web UI that mention "form=" or the "ds" API, so the request style is visible.
    private func discoverStyle() async -> [String] {
        var out = Set<String>()
        guard let index = await fetchText("/webpages/index.html") else { return ["index.html not readable"] }
        var files = ["/webpages/index.html"]
        for ref in Self.matches(#"[A-Za-z0-9_./-]+\.js"#, in: index) where !ref.contains("//") {
            var p = ref
            while p.hasPrefix("./") { p.removeFirst(2) }
            files.append(p.hasPrefix("/") ? p : "/webpages/" + p)
        }
        var names: [String] = []
        for f in files.prefix(25) {
            guard let t = await fetchText(f) else { continue }
            names.append("\(f) (\(t.count) chars)")
            for m in Self.matches(#".{0,60}(form=|/ds[\"'?]|stok=|\.su\.url\(|proxy\(|method[\"']?:).{0,60}"#, in: t) {
                out.insert(m.replacingOccurrences(of: "\n", with: " "))
                if out.count >= 60 { break }
            }
        }
        return ["Script files:"] + names + ["Request-style snippets:"] + out.sorted().prefix(60)
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
        if let (d, _) = try? await post("/device_config?form=config", body: "operation=read") {
            out.append("device_config: " + String(decoding: d.prefix(400), as: UTF8.self))
        }
        progress("Trying both login names…")
        override = nil
        forceAdmin = false
        do {
            try await loginOnce()
            out.append("Login with account name (\(username.isEmpty ? "empty" : "\"\(username)\"")): OK")
            out.append("  status_ipv4 with this login: " + (await rawCall("admin/network?form=status_ipv4", op: "read")))
        } catch {
            out.append("Login with account name (\(username.isEmpty ? "empty" : "\"\(username)\"")): FAILED: \(error.localizedDescription)")
        }
        forceAdmin = true
        do {
            try await loginOnce()
            out.append("Login as \"admin\": OK")
            out.append("  status_ipv4 with this login: " + (await rawCall("admin/network?form=status_ipv4", op: "read")))
        } catch {
            out.append("Login as \"admin\": FAILED: \(error.localizedDescription)")
        }
        forceAdmin = false
        logged = false
        do {
            if !logged { try await login() }
            out.append("Login: OK (account name \(username.isEmpty ? "empty" : "\"\(username)\""), \(plain ? "plain" : "encrypted") requests)")
        } catch {
            out.append("Login: FAILED: \(error.localizedDescription)")
        }
        progress("Reading the router's web pages…")
        let (found, files) = await discoverPages()
        out.append("Web UI files read: \(files); pages found: \(found.count): " + found.joined(separator: ", "))

        progress("Trying request styles…")
        out.append("")
        out.append("Request styles on admin/network?form=status_ipv4:")
        let t = "admin/network?form=status_ipv4"
        out.append("A url+body op:   " + (await rawCall(t, op: "read")))
        out.append("B body op only:  " + (await rawCall(t, op: "read", opInURL: false)))
        out.append("C url op only:   " + (await rawCall(t, op: "read", bodyOp: false)))
        out.append("D json body:     " + (await rawCall(t, op: "read", json: true)))
        out.append("E ds get:        " + (await rawCall("ds", op: "", opInURL: false, rawBody: "{\"method\":\"get\",\"system\":{\"name\":[\"sys\"]}}")))
        out.append("F ds device:     " + (await rawCall("ds", op: "", opInURL: false, rawBody: "{\"method\":\"get\",\"device_info\":{\"name\":\"info\"}}")))
        out.append("G locale:        " + (await rawCall("locale?form=lang", op: "read")))
        out.append("H no stok:       " + (await rawCallNoStok(t)))

        progress("Reading how the web UI makes requests…")
        out.append("")
        out.append(contentsOf: await discoverStyle())

        let known = ["admin/status?form=all", "admin/status?form=router", "admin/status?form=perf",
                     "admin/status?form=client_status", "admin/wireless?form=wireless_2g", "admin/wireless?form=wireless_5g",
                     "admin/firmware?form=upgrade", "admin/system?form=sysmode"]
        let skip = ["logout", "reboot", "reset", "restore", "backup", "factory", "login", "upgrade_fw"]
        let pages = (found + known.filter { !found.contains($0) })
            .filter { p in !skip.contains(where: { p.lowercased().contains($0) }) }
        out.append("")
        out.append("Files read: " + fetched.joined(separator: ", "))
        out.append("")
        out.append("Pages:")
        for (i, p) in pages.prefix(80).enumerated() {
            progress("Asking \(i + 1) of \(min(pages.count, 80)): \(p)")
            out.append("\(p) " + (await rawCall(p, op: "read")))
        }
        out.append("")
        for extra in ["/webpages/modules/login/script.js", "/webpages/modules/main/main.js", "/webpages/config/modules.json", "/webpages/config.json"] {
            if Self.sourceStore[extra] == nil, let t = await fetchText(extra) { Self.sourceStore[extra] = t }
        }
        out.append("Login response headers: " + lastLoginHeaders)
        out.append("Web UI source that builds requests (index.html, the login and main modules, and any file mentioning cgi-bin, stok, luci, encrypt or sign):")
        var budget = 400_000
        for (path, text) in Self.sourceStore.sorted(by: { $0.key < $1.key }) where budget > 0 {
            let part = String(text.prefix(min(60_000, budget)))
            budget -= part.count
            out.append("----- \(path) (\(text.count) chars) -----")
            out.append(part)
        }
        return out.joined(separator: "\n")
    }
}
