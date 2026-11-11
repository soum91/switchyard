import Foundation
import CommonCrypto
import CryptoKit

/// Just enough unsigned big-integer maths for TP-Link's RSA (raw modular exponentiation, 512 to 2048 bits).
struct BigUInt: Equatable {
    var limbs: [UInt32]   // little-endian

    init(_ limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(bytes: [UInt8]) {
        var l: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var v: UInt32 = 0
            for b in bytes[start..<i] { v = (v << 8) | UInt32(b) }
            l.append(v)
            i = start
        }
        self.init(l)
    }

    init?(hex: String) {
        let h = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        var bytes: [UInt8] = []
        var chars = Array(h)
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes: bytes)
    }

    mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let w = i / 32
        guard w < limbs.count else { return false }
        return (limbs[w] >> UInt32(i % 32)) & 1 == 1
    }

    /// Big-endian bytes, left-padded to `count`.
    func bytes(count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var idx = count - 1
        for limb in limbs {
            var v = limb
            for _ in 0..<4 {
                if idx < 0 { return out }
                out[idx] = UInt8(v & 0xff)
                v >>= 8
                idx -= 1
            }
        }
        return out
    }

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var la = a.count, lb = b.count
        while la > 0 && a[la - 1] == 0 { la -= 1 }
        while lb > 0 && b[lb - 1] == 0 { lb -= 1 }
        if la != lb { return la < lb ? -1 : 1 }
        var i = la - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// a -= b, in place (requires a >= b).
    static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let bi: UInt64 = i < b.count ? UInt64(b[i]) : 0
            let ai = UInt64(a[i])
            let d = ai &- bi &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (ai < bi + borrow) ? 1 : 0
        }
    }

    static func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        if a.isEmpty || b.isEmpty { return [] }
        var r = [UInt32](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            var carry: UInt64 = 0
            let ai = UInt64(a[i])
            for j in 0..<b.count {
                let t = ai * UInt64(b[j]) + UInt64(r[i + j]) + carry
                r[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            var k = i + b.count
            while carry > 0 {
                let t = UInt64(r[k]) + carry
                r[k] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
                k += 1
            }
        }
        return r
    }

    /// x mod m by shift-and-subtract (plenty fast for one RSA operation).
    static func mod(_ x: [UInt32], _ m: [UInt32]) -> [UInt32] {
        let mw = BigUInt(m)
        let xw = BigUInt(x)
        if compare(xw.limbs, mw.limbs) < 0 { return xw.limbs }
        var r = [UInt32](repeating: 0, count: mw.limbs.count + 1)
        var i = xw.bitWidth - 1
        while i >= 0 {
            // r = r << 1 | bit
            var carry: UInt32 = xw.bit(i) ? 1 : 0
            for k in 0..<r.count {
                let next = r[k] >> 31
                r[k] = (r[k] << 1) | carry
                carry = next
            }
            if compare(r, mw.limbs) >= 0 { subtract(&r, mw.limbs) }
            i -= 1
        }
        return BigUInt(r).limbs
    }

    func power(_ e: BigUInt, modulus m: BigUInt) -> BigUInt {
        var result: [UInt32] = [1]
        let base = BigUInt.mod(limbs, m.limbs)
        var i = e.bitWidth - 1
        while i >= 0 {
            result = BigUInt.mod(BigUInt.multiply(result, result), m.limbs)
            if e.bit(i) { result = BigUInt.mod(BigUInt.multiply(result, base), m.limbs) }
            i -= 1
        }
        return BigUInt(result)
    }
}

enum TPCrypto {
    /// RSA PKCS#1 v1.5 encryption (what pycryptodome's PKCS1_v1_5 does), hex out.
    static func rsaPKCS1(_ message: [UInt8], nHex: String, eHex: String) throws -> String {
        guard let n = BigUInt(hex: nHex), let e = BigUInt(hex: eHex), !n.isZero else { throw TPError.message("The router sent a bad key.") }
        let k = (n.bitWidth + 7) / 8
        guard message.count <= k - 11 else { throw TPError.message("Password too long for the router's key.") }
        var em = [UInt8](repeating: 0, count: k)
        em[1] = 2
        let psLen = k - message.count - 3
        for i in 0..<psLen {
            var b: UInt8 = 0
            while b == 0 { b = UInt8.random(in: 1...255) }
            em[2 + i] = b
        }
        em[2 + psLen] = 0
        for (i, b) in message.enumerated() { em[3 + psLen + i] = b }
        let c = BigUInt(bytes: em).power(e, modulus: n)
        return hex(c.bytes(count: k))
    }

    /// RSA with OAEP padding (SHA-1, MGF1-SHA-1, empty label), as newer TP-Link firmware signs logins.
    static func rsaOAEP(_ message: [UInt8], nHex: String, eHex: String) throws -> String {
        guard let n = BigUInt(hex: nHex), let e = BigUInt(hex: eHex), !n.isZero else { throw TPError.message("The router sent a bad key.") }
        let k = (n.bitWidth + 7) / 8
        let hLen = 20
        guard message.count <= k - 2 * hLen - 2 else { throw TPError.message("Login signature too long for the router's key.") }
        func sha1(_ b: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: Data(b))) }
        func mgf1(_ seed: [UInt8], _ len: Int) -> [UInt8] {
            var out: [UInt8] = []
            var c: UInt32 = 0
            while out.count < len {
                out += sha1(seed + [UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)])
                c += 1
            }
            return Array(out.prefix(len))
        }
        let lHash = sha1([])
        let ps = [UInt8](repeating: 0, count: k - message.count - 2 * hLen - 2)
        let db = lHash + ps + [1] + message
        let seed = (0..<hLen).map { _ in UInt8.random(in: 0...255) }
        let maskedDB = zip(db, mgf1(seed, k - hLen - 1)).map { $0 ^ $1 }
        let maskedSeed = zip(seed, mgf1(maskedDB, hLen)).map { $0 ^ $1 }
        let em = [0] + maskedSeed + maskedDB
        let c = BigUInt(bytes: em).power(e, modulus: n)
        return hex(c.bytes(count: k))
    }

    static func sha256Hex(_ s: String) -> String { hex(Array(SHA256.hash(data: Data(s.utf8)))) }

    static func hmacSHA256Hex(key: String, _ s: String) -> String {
        hex(Array(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: Data(key.utf8)))))
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func aes(_ input: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, input, input.count,
                             &out, out.count, &moved)
        guard status == kCCSuccess else { throw TPError.message("Couldn't \(encrypt ? "encrypt" : "decrypt") the router's data.") }
        return Array(out.prefix(moved))
    }
}

/// The router's AES session: a 16-character key and IV made of hex digits, like the web UI uses.
struct TPSession {
    let key: String
    let iv: String

    init() {
        func r() -> String { TPCrypto.hex((0..<8).map { _ in UInt8.random(in: 0...255) }) }
        key = r()
        iv = r()
    }

    /// Newer firmware's web UI uses 16 random decimal digits for the key and IV.
    init(digits: Bool) {
        func r() -> String { String((0..<16).map { _ in Character(String(Int.random(in: 0...9))) }) }
        if digits { key = r(); iv = r() } else {
            func h() -> String { TPCrypto.hex((0..<8).map { _ in UInt8.random(in: 0...255) }) }
            key = h(); iv = h()
        }
    }

    /// Newer firmware login signature: RSA-OAEP over "k=&i=&h=&s=" in chunks that fit the key.
    func sgLoginSign(seq: Int, hash: String, nHex: String, eHex: String) throws -> String {
        let bytes = Array("k=\(key)&i=\(iv)&h=\(hash)&s=\(seq)".utf8)
        let k = nHex.count / 2
        let step = min(53, k - 42)
        guard step > 0 else { throw TPError.message("The router's signing key is too small.") }
        var out = ""
        var pos = 0
        while pos < bytes.count {
            out += try TPCrypto.rsaOAEP(Array(bytes[pos..<min(pos + step, bytes.count)]), nHex: nHex, eHex: eHex)
            pos += step
        }
        return out
    }

    /// Newer firmware request signature: HMAC-SHA256 (keyed with "k=&i=") over "h=&s=", 53 characters at a time.
    func sgRequestSign(seq: Int, hash: String) -> String {
        let s = Array("h=\(hash)&s=\(seq)")
        let mac = "k=\(key)&i=\(iv)"
        var out = ""
        var pos = 0
        while pos < s.count {
            out += TPCrypto.hmacSHA256Hex(key: mac, String(s[pos..<min(pos + 53, s.count)]))
            pos += 53
        }
        return out
    }

    func encrypt(_ s: String) throws -> String {
        Data(try TPCrypto.aes(Array(s.utf8), key: Array(key.utf8), iv: Array(iv.utf8), encrypt: true)).base64EncodedString()
    }

    func decrypt(_ b64: String) throws -> String {
        guard let d = Data(base64Encoded: b64) else { throw TPError.message("The router's reply wasn't base64.") }
        let plain = try TPCrypto.aes(Array(d), key: Array(key.utf8), iv: Array(iv.utf8), encrypt: false)
        return String(decoding: plain, as: UTF8.self)
    }

    /// The "sign" field: RSA over the AES key (on login), the password hash and the sequence number, 53 bytes at a time.
    func sign(seq: Int, login: Bool, hash: String, nHex: String, eHex: String) throws -> String {
        let s = login ? "k=\(key)&i=\(iv)&h=\(hash)&s=\(seq)" : "h=\(hash)&s=\(seq)"
        let bytes = Array(s.utf8)
        var out = ""
        var pos = 0
        while pos < bytes.count {
            out += try TPCrypto.rsaPKCS1(Array(bytes[pos..<min(pos + 53, bytes.count)]), nHex: nHex, eHex: eHex)
            pos += 53
        }
        return out
    }
}

enum TPError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
