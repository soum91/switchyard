import SwiftUI

/// The live state of one OpenWrt router and everything the screens can do to it.
@MainActor
final class RouterModel: ObservableObject {
    let link: SwitchyardLink

    @Published var status: RStatus?
    @Published var error: String?
    @Published var notInstalled = false
    @Published var down: Double?
    @Published var up: Double?
    @Published var clients: RClients?
    @Published var wifi: RWifi?
    @Published var domains: RDomains?
    @Published var sys: RSys?
    @Published var busy: Set<String> = []
    @Published var toast: String?

    private var last: (rx: Double, tx: Double, at: Date)?
    private var poller: Task<Void, Never>?

    init(link: SwitchyardLink) { self.link = link }

    func start(every seconds: Double = 3) {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
        do {
            let s = try decodeJSON(RStatus.self, try await link.call("status"))
            if let rx = s.up?.rx, let tx = s.up?.tx {
                let now = Date()
                if let l = last, now.timeIntervalSince(l.at) > 0.5, rx >= l.rx, tx >= l.tx {
                    let dt = now.timeIntervalSince(l.at)
                    down = (rx - l.rx) / dt
                    up = (tx - l.tx) / dt
                }
                last = (rx, tx, now)
            }
            status = s
            error = nil
            notInstalled = false
        } catch RouterError.notInstalled {
            notInstalled = true
            error = RouterError.notInstalled.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    func say(_ t: String) {
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == t { toast = nil }
        }
    }

    /// Runs a method, shows its error, and refreshes the status afterwards.
    @discardableResult
    func run(_ key: String, _ method: String, _ args: [String: Any] = [:], done: String? = nil, timeout: Double = 10) async -> [String: Any]? {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let r = try await link.call(method, args, timeout: timeout)
            if let done { say(done) }
            await refresh()
            return r
        } catch {
            say(error.localizedDescription)
            return nil
        }
    }

    func loadClients() async {
        do { clients = try decodeJSON(RClients.self, try await link.call("clients")) }
        catch { say(error.localizedDescription) }
    }

    func loadWifi() async {
        do { wifi = try decodeJSON(RWifi.self, try await link.call("wifi")) }
        catch { say(error.localizedDescription) }
    }

    func loadDomains() async {
        do { domains = try decodeJSON(RDomains.self, try await link.call("domains")) }
        catch { say(error.localizedDescription) }
    }

    func loadSys() async {
        do { sys = try decodeJSON(RSys.self, try await link.call("sys")) }
        catch { say(error.localizedDescription) }
    }

    // MARK: actions

    func setAdblock(_ on: Bool) async {
        await run("ab", "adblock", ["on": on], done: on ? "Ad blocking on. It can take a minute to load the lists." : "Ad blocking paused.")
    }

    func setWarp(_ on: Bool) async {
        await run("warp", "warp", ["on": on], done: on ? "WARP starting." : "WARP off. Traffic goes straight out.")
    }

    func setLeds(_ on: Bool) async {
        await run("led", "leds", ["on": on], done: on ? "Lights on." : "Lights off.")
    }

    func setNetwatch(_ on: Bool) async {
        await run("nw", "netwatch", ["on": on], done: on ? "Logging drops every minute." : "Drop logging off.")
    }

    func setLedSchedule(enabled: Bool, off: Date, on: Date) async {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        await run("sched", "ledsched", ["enabled": enabled, "off": f.string(from: off), "on": f.string(from: on)],
                  done: enabled ? "Schedule saved." : "Schedule removed.")
    }

    func kick(_ c: RClient) async {
        await run("c-" + c.m, "kick", ["mac": c.m], done: "\(c.name) kicked off Wi-Fi.")
        await loadClients()
    }

    func block(_ c: RClient, _ on: Bool) async {
        await run("c-" + c.m, "block", ["mac": c.m, "on": on], done: on ? "\(c.name) has no internet now." : "\(c.name) is back online.")
        await loadClients()
    }

    func domain(_ d: String, _ action: String) async {
        let msg = action == "block" ? "Blocking \(d)." : action == "allow" ? "Always allowing \(d)." : "Removed \(d)."
        await run("dom", "domain", ["domain": d, "action": action], done: msg)
        await loadDomains()
    }

    func reboot() async {
        await run("reboot", "reboot", done: "Rebooting. It takes about a minute.")
    }
}
