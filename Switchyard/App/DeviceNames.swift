import SwiftUI

/// Names for devices on a router's list.
/// Order: a name you set here, then the name the device told the router (DHCP hostname),
/// then the maker looked up from the first part of its MAC address, then the IP.
/// The maker table (Resources/oui.txt) is the public IEEE vendor registry, looked up offline.
final class DeviceNames: ObservableObject {
    static let shared = DeviceNames()

    private static let key = "switchyard.deviceNicknames"
    @Published private(set) var nicknames: [String: String]

    private init() {
        nicknames = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
    }

    // MARK: MAC helpers

    /// "AA-BB-CC-DD-EE-FF", "aa:bb:cc:dd:ee:ff" or "aabbccddeeff" -> "AABBCCDDEEFF"
    static func clean(_ mac: String) -> String {
        String(mac.uppercased().filter { $0.isHexDigit })
    }

    /// Phones and laptops often use a made-up "private" Wi-Fi address that changes per network.
    /// It's marked by bit 1 of the first byte, and it carries no maker information.
    static func isPrivate(_ mac: String) -> Bool {
        let m = clean(mac)
        guard m.count >= 2, let first = UInt8(m.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }

    private static let table: [String: String] = {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        out.reserveCapacity(46_000)
        text.enumerateLines { line, _ in
            guard let tab = line.firstIndex(of: "\t") else { return }
            out[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return out
    }()

    /// The maker for a MAC address, or nil when it's a private address or isn't in the registry.
    static func vendor(_ mac: String) -> String? {
        let m = clean(mac)
        guard m.count >= 6, !isPrivate(m) else { return nil }
        for n in [9, 7, 6] where m.count >= n {
            if let v = table[String(m.prefix(n))], !v.hasPrefix("IEEE Registration") { return v }
        }
        return nil
    }

    // MARK: Names

    func nickname(_ mac: String) -> String? { nicknames[Self.clean(mac)] }

    func setNickname(_ name: String?, for mac: String) {
        let k = Self.clean(mac)
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { nicknames.removeValue(forKey: k) } else { nicknames[k] = t }
        UserDefaults.standard.set(nicknames, forKey: Self.key)
    }

    /// What to show as the device's name.
    func title(host: String?, mac: String, ip: String?) -> String {
        if let n = nickname(mac) { return n }
        if let h = host?.trimmingCharacters(in: .whitespaces), !h.isEmpty, h != "*" { return h }
        if let v = Self.vendor(mac) { return v }
        if Self.isPrivate(mac) { return "Private address" }
        if let ip, !ip.isEmpty { return ip }
        return mac.uppercased()
    }

    /// A short note under the name saying where the guess came from, or nil when the name speaks for itself.
    func note(host: String?, mac: String) -> String? {
        let named = nickname(mac) != nil || !(host?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        if let v = Self.vendor(mac) { return named ? v : "Made by \(v) (guessed from its MAC)" }
        if Self.isPrivate(mac) { return named ? nil : "Phone or laptop using a private Wi-Fi address; the maker can't be told" }
        return nil
    }
}

/// Long-press "Rename" for a device row. Names are kept on this phone only.
private struct DeviceRename: ViewModifier {
    @Binding var mac: String?
    @ObservedObject private var names = DeviceNames.shared
    @State private var draft = ""

    func body(content: Content) -> some View {
        content.alert("Rename device", isPresented: Binding(get: { mac != nil }, set: { if !$0 { mac = nil } })) {
            TextField("Name", text: $draft)
            Button("Save") { if let m = mac { names.setNickname(draft, for: m) } }
            Button("Use the router's name", role: .destructive) { if let m = mac { names.setNickname(nil, for: m) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only changes how this phone shows it. The router isn't touched.")
        }
        .onChange(of: mac) { _, m in draft = m.flatMap { names.nickname($0) } ?? "" }
    }
}

extension View {
    func deviceRename(_ mac: Binding<String?>) -> some View { modifier(DeviceRename(mac: mac)) }
}
