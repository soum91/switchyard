import Foundation

// What the router plugin returns. Everything is optional: older plugins and odd setups leave things out.

struct RStatus: Decodable, Equatable {
    struct Mem: Decodable, Equatable { var total: Double?; var avail: Double? }
    struct Addr: Decodable, Equatable { var ip: String?; var mask: Int? }
    struct Up: Decodable, Equatable {
        var iface: String?; var dev: String?; var ip: String?; var mask: Int?; var gw: String?
        var ssid: String?; var signal: Int?; var rate: Double?; var rx: Double?; var tx: Double?
    }
    struct Warp: Decodable, Equatable { var iface: String?; var up: Bool?; var route: Bool?; var hs: Int?; var auto: Bool? }
    struct Adblock: Decodable, Equatable {
        var pkg: String?; var on: Bool?; var state: String?; var n: Int?; var custom: Int?; var paused: Bool?
    }
    struct Led: Decodable, Equatable { var off: Bool?; var n: Int?; var sch: Bool?; var offAt: String?; var onAt: String? }
    struct Netwatch: Decodable, Equatable { var on: Bool?; var n: Int? }
    struct Guest: Decodable, Equatable { var on: Bool? }
    struct Storage: Decodable, Equatable { var total: Double?; var free: Double? }

    var v: Int?
    var host: String?
    var model: String?
    var release: String?
    var kernel: String?
    var uptime: Int?
    var load: [Double]?
    var mem: Mem?
    var time: String?
    var zone: String?
    var lan: Addr?
    var up: Up?
    var warp: Warp?
    var ab: Adblock?
    var led: Led?
    var nw: Netwatch?
    var guest: Guest?
    var clients: Int?
    var storage: Storage?

    var memUsed: Double? {
        guard let t = mem?.total, let a = mem?.avail, t > 0 else { return nil }
        return 1 - a / t
    }

    var warpHealthy: Bool { warp?.up == true && (warp?.hs ?? -1) >= 0 && (warp?.hs ?? 999) < 180 }
}

struct RClient: Decodable, Equatable, Identifiable {
    var m: String
    var i: String?
    var n: String?
    var b: String?
    var s: Int?
    var r: Double?
    var t: Double?
    var a: Int?
    var w: String?
    var g: Bool?
    var x: Bool?

    var id: String { m }
    var name: String { (n?.isEmpty == false ? n : nil) ?? i ?? m.uppercased() }
    var blocked: Bool { x == true }
    var wired: Bool { b == nil || b == "lan" }
    var bandLabel: String {
        switch b {
        case "2g": return "2.4 GHz"
        case "5g": return "5 GHz"
        case "6g": return "6 GHz"
        case "lan", nil: return "Wired"
        default: return b ?? "Wi-Fi"
        }
    }
}

struct RClients: Decodable, Equatable {
    var c: [RClient]?
    var off: [RClient]?
}

struct RWifi: Decodable, Equatable {
    struct Radio: Decodable, Equatable, Identifiable {
        var sec: String
        var band: String?
        var channel: String?
        var live: Int?
        var htmode: String?
        var txpower: String?
        var country: String?
        var disabled: Bool?
        var locked: Bool?
        var id: String { sec }
        var bandLabel: String { band == "2g" ? "2.4 GHz" : band == "5g" ? "5 GHz" : band == "6g" ? "6 GHz" : sec }
        var channels: [String] {
            switch band {
            case "2g": return ["auto"] + (1...11).map(String.init)
            case "5g": return ["auto"] + ["36", "40", "44", "48", "52", "56", "60", "64", "100", "104", "108", "112", "116", "120", "124", "128", "132", "136", "140", "144", "149", "153", "157", "161", "165"]
            default: return ["auto"]
            }
        }
    }
    struct Iface: Decodable, Equatable, Identifiable {
        var sec: String
        var radio: String?
        var mode: String?
        var ssid: String?
        var enc: String?
        var key: String?
        var disabled: Bool?
        var hidden: Bool?
        var net: [String]?
        var ifname: String?
        var guest: Bool?
        var id: String { sec }
        var isUplink: Bool { mode == "sta" }
    }
    var radios: [Radio]?
    var ifaces: [Iface]?
    var guest: Bool?
}

struct RDomains: Decodable, Equatable {
    struct Manual: Decodable, Equatable, Identifiable { var d: String; var f: String?; var on: Bool?; var id: String { (f ?? "") + "/" + d } }
    struct List: Decodable, Equatable, Identifiable { var f: String; var n: Int?; var on: Bool?; var id: String { f } }
    var pkg: String?
    var block: [String]?
    var allow: [String]?
    var manual: [Manual]?
    var lists: [List]?
}

struct RDiag: Decodable, Equatable {
    struct Ping: Decodable, Equatable { var host: String?; var ok: Bool?; var recv: Int?; var ms: Double? }
    struct DNS: Decodable, Equatable { var ok: Bool? }
    struct Warp: Decodable, Equatable { var iface: String?; var hs: Int? }
    var gw: Ping?
    var net: Ping?
    var dns: DNS?
    var routes: [String]?
    var warp: Warp?
}

struct RLogs: Decodable, Equatable { var kind: String?; var lines: [String]? }

struct RSys: Decodable, Equatable {
    var model: String?
    var board: String?
    var release: String?
    var target: String?
    var kernel: String?
    var packages: Int?
    var upgrades: [String]?
    var checking: Bool?
}

struct RScan: Decodable, Equatable {
    struct Net: Decodable, Equatable, Identifiable { var s: String?; var c: Int?; var g: Int?; var b: String?; var id: String { (b ?? "") + (s ?? "") + String(c ?? 0) } }
    var radio: String?
    var nets: [Net]?
}

enum RFmt {
    static func uptime(_ s: Int?) -> String {
        guard let s else { return "–" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func rate(_ bytesPerSec: Double?) -> String {
        guard let b = bytesPerSec else { return "–" }
        let bits = b * 8
        if bits >= 1_000_000 { return String(format: "%.1f Mbps", bits / 1_000_000) }
        if bits >= 1_000 { return String(format: "%.0f kbps", bits / 1_000) }
        return String(format: "%.0f bps", bits)
    }

    static func linkRate(_ kbit: Double?) -> String? {
        guard let k = kbit, k > 0 else { return nil }
        return k >= 1000 ? String(format: "%.0f Mbps", k / 1000) : String(format: "%.0f kbps", k)
    }

    static func kb(_ kb: Double?) -> String {
        guard let kb else { return "–" }
        if kb >= 1024 * 1024 { return String(format: "%.1f GB", kb / 1024 / 1024) }
        if kb >= 1024 { return String(format: "%.1f MB", kb / 1024) }
        return String(format: "%.0f KB", kb)
    }

    static func bytes(_ b: Double?) -> String {
        guard let b else { return "–" }
        return kb(b / 1024)
    }

    static func ago(_ s: Int?) -> String {
        guard let s, s >= 0 else { return "never" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func bars(_ dbm: Int?) -> Int {
        guard let r = dbm, r != 0 else { return 0 }
        return r > -55 ? 4 : r > -65 ? 3 : r > -75 ? 2 : 1
    }
}
