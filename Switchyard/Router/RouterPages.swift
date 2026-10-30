import SwiftUI

// MARK: - Devices

struct ClientsView: View {
    @ObservedObject var model: RouterModel
    @State private var search = ""

    private var online: [RClient] {
        let all = model.clients?.c ?? []
        let f = search.isEmpty ? all : all.filter { ($0.n ?? "").localizedCaseInsensitiveContains(search) || ($0.i ?? "").contains(search) || $0.m.contains(search.lowercased()) }
        return f.sorted { a, b in
            if a.wired != b.wired { return !a.wired }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(online) { c in row(c) }
            } header: {
                Text("\(online.count) online")
            } footer: {
                Text("Swipe a device to kick it off Wi-Fi or cut its internet. A blocked device stays on the network but can't get out.")
            }
            if let off = model.clients?.off, !off.isEmpty {
                Section("Blocked, not connected") {
                    ForEach(off) { c in row(c) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Devices")
        .searchable(text: $search)
        .refreshable { await model.loadClients() }
        .task { await model.loadClients() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
    }

    private func row(_ c: RClient) -> some View {
        HStack(spacing: 12) {
            Image(systemName: c.wired ? "cable.connector" : "wifi")
                .frame(width: 24)
                .foregroundStyle(c.blocked ? Theme.bad : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).lineLimit(1)
                    if c.g == true { Text("GUEST").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                    if c.blocked { Text("BLOCKED").font(.caption2.weight(.bold)).foregroundStyle(Theme.bad) }
                }
                Text([c.i, c.bandLabel, RFmt.linkRate(c.r)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(c.m.uppercased()).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
            if model.busy.contains("c-" + c.m) { ProgressView() }
            else if !c.wired { SignalBars(bars: RFmt.bars(c.s)) }
        }
        .swipeActions(edge: .trailing) {
            Button(c.blocked ? "Unblock" : "Block") { Task { await model.block(c, !c.blocked) } }
                .tint(c.blocked ? Theme.good : Theme.bad)
            if !c.wired {
                Button("Kick") { Task { await model.kick(c) } }.tint(.orange)
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = c.m } label: { Label("Copy MAC address", systemImage: "doc.on.doc") }
            if let ip = c.i { Button { UIPasteboard.general.string = ip } label: { Label("Copy IP address", systemImage: "doc.on.doc") } }
        }
    }
}

// MARK: - Blocked sites

struct BlockingView: View {
    @ObservedObject var model: RouterModel
    @State private var entry = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("example.com", text: $entry)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                    if model.busy.contains("dom") { ProgressView() }
                }
                HStack {
                    Button("Block") { submit("block") }
                    Spacer()
                    if model.domains?.pkg != nil {
                        Button("Always allow") { submit("allow") }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text(model.domains?.pkg != nil
                     ? "Blocks and allows go into adblock-fast, which reloads its lists in the background (about a minute)."
                     : "Blocks go into a dnsmasq file on the router and work right away.")
            }

            if let d = model.domains {
                if let b = d.block, !b.isEmpty {
                    Section("Blocked by you") {
                        ForEach(b, id: \.self) { x in domainRow(x, icon: "nosign", color: Theme.bad) }
                    }
                }
                if let a = d.allow, !a.isEmpty {
                    Section("Always allowed") {
                        ForEach(a, id: \.self) { x in domainRow(x, icon: "checkmark.shield", color: Theme.good) }
                    }
                }
                if let m = d.manual, !m.isEmpty {
                    Section("Hand-made blocks (dnsmasq)") {
                        ForEach(m) { x in
                            domainRow(x.d, icon: "nosign", color: x.on == false ? .secondary : Theme.bad, note: x.f)
                        }
                    }
                }
                if let l = d.lists, !l.isEmpty {
                    Section("Block lists") {
                        ForEach(l) { x in
                            HStack {
                                Text(x.f)
                                Spacer()
                                Text("\((x.n ?? 0).formatted()) domains\(x.on == false ? " · paused" : "")").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Blocked sites")
        .refreshable { await model.loadDomains() }
        .task { await model.loadDomains() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
    }

    private func submit(_ action: String) {
        let d = entry.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        entry = ""
        Task { await model.domain(d, action) }
    }

    private func domainRow(_ d: String, icon: String, color: Color, note: String? = nil) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading) {
                Text(d)
                if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) { Task { await model.domain(d, "remove") } }
        }
    }
}

// MARK: - Wi-Fi

struct WifiView: View {
    @ObservedObject var model: RouterModel
    @State private var editing: RWifi.Iface?
    @State private var guestSheet = false
    @State private var scanning: String?
    @State private var scan: RScan?

    var body: some View {
        List {
            if let w = model.wifi {
                ForEach(w.radios ?? []) { r in
                    Section {
                        radioRow(r)
                        ForEach((w.ifaces ?? []).filter { $0.radio == r.sec }) { i in
                            Button { editing = i } label: { ifaceRow(i) }
                                .foregroundStyle(.primary)
                        }
                    } header: {
                        Text(r.bandLabel)
                    } footer: {
                        if r.locked == true {
                            Text("This radio also connects to the upstream Wi-Fi, so it stays on that network's channel.")
                        }
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { w.guest == true }, set: { on in
                        if on { guestSheet = true } else { Task { await guestOff() } }
                    })) {
                        Label("Guest network", systemImage: "person.2.wave.2")
                    }
                    .disabled(model.busy.contains("guest"))
                } footer: {
                    Text("A separate network on both bands that reaches the internet but not your devices or the router's settings.")
                }
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Wi-Fi")
        .refreshable { await model.loadWifi() }
        .task { await model.loadWifi() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .sheet(item: $editing) { i in
            IfaceEditor(model: model, iface: i)
        }
        .sheet(isPresented: $guestSheet) {
            GuestSheet(model: model)
        }
        .sheet(item: Binding(get: { scan.map { ScanBox(scan: $0) } }, set: { if $0 == nil { scan = nil } })) { box in
            ScanSheet(scan: box.scan)
        }
    }

    private func guestOff() async {
        await model.run("guest", "guest", ["on": false], done: "Guest network off.")
        await model.loadWifi()
    }

    private func radioRow(_ r: RWifi.Radio) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Channel")
                Spacer()
                if r.locked == true {
                    Text(r.live.map(String.init) ?? r.channel ?? "auto").foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(r.channels, id: \.self) { ch in
                            Button(ch == "auto" ? "Auto" : ch) {
                                Task {
                                    await model.run("ch-" + r.sec, "wifi_set", ["sec": r.sec, "channel": ch], done: "Channel set. Wi-Fi restarts for a few seconds.")
                                    await model.loadWifi()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text((r.channel ?? "auto") == "auto" ? "Auto" + (r.live.map { " (\($0))" } ?? "") : (r.channel ?? ""))
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                    }
                }
                if model.busy.contains("ch-" + r.sec) { ProgressView() }
            }
            HStack {
                Button {
                    Task {
                        scanning = r.sec
                        defer { scanning = nil }
                        if let o = await model.run("scan-" + r.sec, "scan", ["radio": r.sec], timeout: 20),
                           let s = try? decodeJSON(RScan.self, o) { scan = s }
                    }
                } label: {
                    Label(scanning == r.sec ? "Scanning…" : "Scan nearby networks", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(scanning != nil)
                Spacer()
                Toggle("Radio on", isOn: Binding(get: { r.disabled != true }, set: { on in
                    Task {
                        await model.run("ch-" + r.sec, "wifi_set", ["sec": r.sec, "disabled": !on], done: on ? "Radio on." : "Radio off.")
                        await model.loadWifi()
                    }
                }))
                .labelsHidden()
                .disabled(r.locked == true)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
    }

    private func ifaceRow(_ i: RWifi.Iface) -> some View {
        HStack(spacing: 12) {
            Image(systemName: i.isUplink ? "arrow.down.to.line" : i.guest == true ? "person.2" : "wifi")
                .frame(width: 24)
                .foregroundStyle(i.disabled == true ? .secondary : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.ssid ?? i.sec)
                Text(i.isUplink ? "Upstream connection" : (i.guest == true ? "Guest" : "Your network") + (i.hidden == true ? " · hidden" : "") + (i.disabled == true ? " · off" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct ScanBox: Identifiable { let scan: RScan; var id: String { scan.radio ?? "scan" } }

struct ScanSheet: View {
    let scan: RScan
    @Environment(\.dismiss) private var dismiss

    private var byChannel: [(Int, Int)] {
        var d: [Int: Int] = [:]
        for n in scan.nets ?? [] { if let c = n.c { d[c, default: 0] += 1 } }
        return d.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Networks per channel") {
                    ForEach(byChannel, id: \.0) { item in
                        HStack {
                            Text("Channel \(item.0)")
                            Spacer()
                            Text("\(item.1)").foregroundStyle(item.1 > 3 ? Theme.bad : .secondary)
                        }
                    }
                }
                Section("Nearby") {
                    ForEach(scan.nets ?? []) { n in
                        HStack {
                            VStack(alignment: .leading) {
                                Text((n.s ?? "").isEmpty ? "(hidden)" : n.s ?? "")
                                Text("Channel \(n.c.map(String.init) ?? "?")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(n.g.map { "\($0) dBm" } ?? "").font(.caption).foregroundStyle(.secondary)
                            SignalBars(bars: RFmt.bars(n.g))
                        }
                    }
                }
            }
            .navigationTitle("Scan")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct IfaceEditor: View {
    @ObservedObject var model: RouterModel
    let iface: RWifi.Iface
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var key = ""
    @State private var hidden = false
    @State private var enabled = true
    @State private var showKey = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if iface.isUplink {
                    Section {
                        Text("This is how the router gets its internet. Change it only if the upstream network's name or password changed, or the router will go offline.")
                            .font(.footnote).foregroundStyle(Theme.bad)
                    }
                }
                Section("Network") {
                    TextField("Name", text: $ssid).autocorrectionDisabled().textInputAutocapitalization(.never)
                    HStack {
                        if showKey {
                            TextField("Password", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
                        } else {
                            SecureField("Password", text: $key)
                        }
                        Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                    }
                    if !iface.isUplink {
                        Toggle("Hidden", isOn: $hidden)
                    }
                    Toggle("On", isOn: $enabled)
                }
                Section {
                    LabeledContent("Security", value: iface.enc ?? "–")
                    if let i = iface.ifname { LabeledContent("Interface", value: i) }
                }
            }
            .navigationTitle(iface.ssid ?? iface.sec)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { save() }.disabled(ssid.isEmpty) }
                }
            }
            .onAppear {
                ssid = iface.ssid ?? ""
                key = iface.key ?? ""
                hidden = iface.hidden == true
                enabled = iface.disabled != true
            }
        }
    }

    private func save() {
        var args: [String: Any] = ["sec": iface.sec]
        if ssid != (iface.ssid ?? "") { args["ssid"] = ssid }
        if key != (iface.key ?? "") { args["key"] = key }
        if hidden != (iface.hidden == true) { args["hidden"] = hidden }
        if enabled != (iface.disabled != true) { args["disabled"] = !enabled }
        guard args.count > 1 else { dismiss(); return }
        saving = true
        Task {
            let r = await model.run("wifi", "wifi_set", args, done: "Saved. Wi-Fi restarts for a few seconds, phones on it will reconnect.")
            saving = false
            if r != nil {
                await model.loadWifi()
                dismiss()
            }
        }
    }
}

struct GuestSheet: View {
    @ObservedObject var model: RouterModel
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = "Guest"
    @State private var key = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $ssid).autocorrectionDisabled()
                    TextField("Password (8+ characters)", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
                } footer: {
                    Text("Guests get their own 192.168.9.x network. They can't see your devices, and devices on it can't see each other.")
                }
                Section {
                    Button("Make a random password") {
                        let a = Array("abcdefghjkmnpqrstuvwxyz23456789")
                        key = String((0..<12).map { _ in a.randomElement()! })
                    }
                }
            }
            .navigationTitle("Guest network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Turn on") {
                            saving = true
                            Task {
                                let r = await model.run("guest", "guest", ["on": true, "ssid": ssid, "key": key], done: "Guest network coming up. Give it 20 seconds.", timeout: 15)
                                saving = false
                                await model.loadWifi()
                                if r != nil { dismiss() }
                            }
                        }
                        .disabled(ssid.isEmpty || key.count < 8)
                    }
                }
            }
        }
    }
}

// MARK: - Light schedule

struct LedScheduleView: View {
    @ObservedObject var model: RouterModel
    @State private var enabled = false
    @State private var off = 23 * 60
    @State private var on = 7 * 60
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Turn the lights off at night", isOn: $enabled)
                if enabled {
                    DatePicker("Off at", selection: binding($off), displayedComponents: .hourAndMinute)
                    DatePicker("On at", selection: binding($on), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Runs on the router itself (cron), in its own time zone\(model.status?.zone.map { ", \($0)" } ?? ""). Replaces the old light lines in the crontab.")
            }
            Section {
                Button {
                    Task { await model.setLedSchedule(enabled: enabled, off: off.clock, on: on.clock) }
                } label: {
                    HStack {
                        Text("Save schedule")
                        if model.busy.contains("sched") { Spacer(); ProgressView() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Light schedule")
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .onAppear {
            guard !loaded, let l = model.status?.led else { return }
            loaded = true
            enabled = l.sch == true
            if let o = l.offAt.flatMap(Self.minutes) { off = o }
            if let o = l.onAt.flatMap(Self.minutes) { on = o }
        }
    }

    private func binding(_ m: Binding<Int>) -> Binding<Date> {
        Binding(get: { m.wrappedValue.clock }, set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            m.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }
}

private extension Int {
    var clock: Date { Calendar.current.date(bySettingHour: self / 60, minute: self % 60, second: 0, of: .now) ?? .now }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @ObservedObject var model: RouterModel
    @State private var diag: RDiag?
    @State private var running = false
    @State private var kind = "netwatch"
    @State private var logs: [String] = []
    @State private var loadingLogs = false

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        running = true
                        if let o = await model.run("diag", "diag", timeout: 20) { diag = try? decodeJSON(RDiag.self, o) }
                        running = false
                    }
                } label: {
                    HStack { Text("Run connection test"); if running { Spacer(); ProgressView() } }
                }
                if let d = diag {
                    if let g = d.gw { pingRow("Upstream router", g) }
                    if let n = d.net { pingRow("Internet (1.1.1.1)", n) }
                    HStack {
                        Text("DNS")
                        Spacer()
                        Image(systemName: d.dns?.ok == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(d.dns?.ok == true ? Theme.good : Theme.bad)
                    }
                    if let w = d.warp {
                        LabeledContent("WARP handshake", value: RFmt.ago(w.hs))
                    }
                    ForEach(d.routes ?? [], id: \.self) { r in
                        Text(r).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                if let d = diag { Text(verdict(d)) }
            }

            Section {
                Picker("Log", selection: $kind) {
                    Text("Drops").tag("netwatch")
                    Text("System").tag("system")
                    Text("Kernel").tag("kernel")
                }
                .pickerStyle(.segmented)
                if loadingLogs { ProgressView() }
                if logs.isEmpty && !loadingLogs {
                    Text(kind == "netwatch" ? "No drops logged." : "Nothing here.").foregroundStyle(.secondary)
                }
                ForEach(Array(logs.reversed().enumerated()), id: \.offset) { _, l in
                    Text(l).font(.caption2.monospaced()).textSelection(.enabled)
                }
                if kind == "netwatch" && !logs.isEmpty {
                    Button("Clear drop log", role: .destructive) {
                        Task { _ = await model.run("logs", "logs", ["kind": "clear"], done: "Cleared."); await loadLogs() }
                    }
                }
            } header: {
                Text("Logs (newest first)")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Diagnostics")
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .task(id: kind) { await loadLogs() }
        .refreshable { await loadLogs() }
    }

    private func loadLogs() async {
        loadingLogs = true
        defer { loadingLogs = false }
        do {
            let r = try decodeJSON(RLogs.self, try await model.link.call("logs", ["kind": kind, "lines": 150], timeout: 12))
            logs = r.lines ?? []
        } catch {
            model.say(error.localizedDescription)
        }
    }

    private func pingRow(_ title: String, _ p: RDiag.Ping) -> some View {
        HStack {
            Text(title)
            Spacer()
            if p.ok == true, let ms = p.ms { Text(String(format: "%.0f ms", ms)).foregroundStyle(.secondary) }
            Image(systemName: p.ok == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(p.ok == true ? Theme.good : Theme.bad)
        }
    }

    private func verdict(_ d: RDiag) -> String {
        if d.gw?.ok == false { return "The router can't reach the upstream router. The Wi-Fi link to it is down or it's rebooting." }
        if d.net?.ok == false { return "The upstream router answers but the internet doesn't. If WARP is on, try turning it off." }
        if d.dns?.ok == false { return "The internet works but names don't resolve. Check ad blocking and dnsmasq." }
        return "Everything answers."
    }
}

// MARK: - System

struct SystemView: View {
    @ObservedObject var model: RouterModel
    @State private var confirmReboot = false

    var body: some View {
        List {
            if let s = model.sys {
                Section("Router") {
                    LabeledContent("Model", value: s.model ?? "–")
                    LabeledContent("Firmware", value: s.release ?? "–")
                    LabeledContent("Target", value: s.target ?? "–")
                    LabeledContent("Kernel", value: s.kernel ?? "–")
                    LabeledContent("Packages", value: s.packages.map(String.init) ?? "–")
                    if let st = model.status?.storage {
                        LabeledContent("Free space", value: "\(RFmt.kb(st.free)) of \(RFmt.kb(st.total))")
                    }
                    if let m = model.status?.mem {
                        LabeledContent("Free memory", value: "\(RFmt.bytes(m.avail)) of \(RFmt.bytes(m.total))")
                    }
                }
                Section {
                    Button {
                        Task {
                            await model.run("up", "upgrades")
                            for _ in 0..<20 {
                                try? await Task.sleep(for: .seconds(3))
                                await model.loadSys()
                                if model.sys?.checking != true { break }
                            }
                        }
                    } label: {
                        HStack { Text("Check for package updates"); if s.checking == true { Spacer(); ProgressView() } }
                    }
                    .disabled(s.checking == true)
                    if let u = s.upgrades {
                        if u.isEmpty { Text("Everything is up to date.").foregroundStyle(.secondary) }
                        ForEach(u, id: \.self) { Text($0).font(.caption.monospaced()) }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("This only lists them. Updating packages on a router this small is safer from SSH, one at a time.")
                }
            } else {
                ProgressView()
            }
            Section {
                Button("Reboot router", role: .destructive) { confirmReboot = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("System")
        .task { await model.loadSys() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .confirmationDialog("Reboot the router?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { Task { await model.reboot() } }
        } message: {
            Text("Everything on it drops for about a minute. The drop log and the WARP route come back on their own.")
        }
    }
}
