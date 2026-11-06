import SwiftUI

// Junction on the router: several internet sources at once.

struct RUplinks: Decodable, Equatable {
    struct Link: Decodable, Equatable, Identifiable {
        var iface: String
        var name: String?
        var enabled: Int?
        var up: Int?
        var healthy: Bool?
        var dev: String?
        var ip: String?
        var gw: String?
        var ssid: String?
        var signal: Int?
        var rate: Int?
        var rtt: Double?
        var loss: Int?
        var weight: String?
        var share: Int?
        var reason: String?
        var id: String { iface }
        var title: String { (name?.isEmpty == false ? name : nil) ?? ssid ?? iface }
    }
    struct Cfg: Decodable, Equatable, Identifiable {
        var sec: String
        var iface: String?
        var name: String?
        var weight: String?
        var enabled: Bool?
        var managed: Bool?
        var id: String { sec }
    }
    struct Radio: Decodable, Equatable, Identifiable {
        var sec: String
        var band: String?
        var busy: String?
        var id: String { sec }
        var bandLabel: String { band == "2g" ? "2.4 GHz" : band == "5g" ? "5 GHz" : band == "6g" ? "6 GHz" : sec }
    }
    var installed: Bool?
    var on: Bool?
    var enabled: Int?
    var mode: String?
    var active: String?
    var min_signal: Int?
    var uplinks: [Link]?
    var cfg: [Cfg]?
    var radios: [Radio]?

    func cfg(for iface: String) -> Cfg? { cfg?.first { $0.iface == iface } }
}

struct SourcesView: View {
    @ObservedObject var model: RouterModel
    @State private var data: RUplinks?
    @State private var adding = false
    @State private var editing: RUplinks.Link?
    @State private var poll: Task<Void, Never>?

    var body: some View {
        List {
            if let d = data {
                if d.installed != true {
                    Section {
                        Text("Junction isn't on the router yet. It lets the router use several internet sources at once (one per radio) and drop the ones that go bad. Run this on the router over SSH:")
                            .font(.footnote)
                        JunctionInstall()
                    }
                } else {
                    overview(d)
                    Section {
                        ForEach(d.uplinks ?? []) { u in
                            Button { editing = u } label: { row(u, d) }.foregroundStyle(.primary)
                        }
                        if d.radios?.contains(where: { $0.busy == nil }) == true {
                            Button { adding = true } label: { Label("Add a source", systemImage: "plus.circle") }
                        }
                    } header: {
                        Text("Sources")
                    } footer: {
                        Text("Each radio can hold one source. Whichever radio connects to a source stays on that source's channel, so your own Wi-Fi on that band moves with it. A source added here that can't connect within 90 s is switched off, because until it connects that radio's own Wi-Fi stays down.")
                    }
                    settings(d)
                }
            } else {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Internet sources")
        .refreshable { await load() }
        .onAppear {
            poll?.cancel()
            poll = Task {
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        }
        .onDisappear { poll?.cancel() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .sheet(isPresented: $adding) {
            AddSourceSheet(model: model, radios: (data?.radios ?? []).filter { $0.busy == nil }) { await load() }
        }
        .sheet(item: $editing) { u in
            SourceEditor(model: model, link: u, cfg: data?.cfg(for: u.iface), mode: data?.mode ?? "balance") { await load() }
        }
    }

    private func load() async {
        do { data = try decodeJSON(RUplinks.self, try await model.link.call("uplinks", [:], timeout: 10)) }
        catch { model.say(error.localizedDescription) }
    }

    private func overview(_ d: RUplinks) -> some View {
        Section {
            let healthy = (d.uplinks ?? []).filter { $0.healthy == true }.count
            let total = (d.uplinks ?? []).count
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.on == false ? "Off" : d.mode == "failover" ? "One source at a time" : "Using every working source")
                        .font(.headline)
                    Text(d.on == false ? "Traffic uses OpenWrt's normal routing." : "\(healthy) of \(total) working")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { d.on != false }, set: { on in
                    Task { await model.run("jc", "uplink_set", ["on": on], done: on ? "Junction on." : "Junction off."); await load() }
                }))
                .labelsHidden()
            }
            if d.on != false, total > 0 {
                ShareBar(links: d.uplinks ?? [])
            }
        }
    }

    private func row(_ u: RUplinks.Link, _ d: RUplinks) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(u.enabled == 0 ? Color.secondary : u.healthy == true ? Theme.good : Theme.bad)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(u.title)
                    if d.active == u.iface && d.on != false {
                        Text("MAIN").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                    }
                }
                Text(detail(u)).font(.caption).foregroundStyle(u.healthy == true || u.enabled == 0 ? .secondary : Theme.bad)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(u.share ?? 0)%").font(.headline.monospacedDigit())
                if u.signal != nil { SignalBars(bars: RFmt.bars(u.signal)) }
            }
        }
    }

    private func detail(_ u: RUplinks.Link) -> String {
        if u.enabled == 0 { return "Off" }
        if u.healthy != true { return u.reason?.isEmpty == false ? u.reason! : "Down" }
        var p: [String] = []
        if let s = u.signal { p.append("\(s) dBm") }
        if let r = u.rate { p.append("\(r) Mbit/s") }
        if let t = u.rtt { p.append(String(format: "%.0f ms", t)) }
        if let l = u.loss, l > 0 { p.append("\(l)% loss") }
        return p.isEmpty ? (u.ip ?? "Working") : p.joined(separator: " · ")
    }

    private func settings(_ d: RUplinks) -> some View {
        Section {
            Picker("Mode", selection: Binding(get: { d.mode ?? "balance" }, set: { m in
                Task { await model.run("jc", "uplink_set", ["mode": m], done: m == "balance" ? "Spreading over every source." : "One source at a time."); await load() }
            })) {
                Text("Spread").tag("balance")
                Text("Failover").tag("failover")
            }
            .pickerStyle(.segmented)
            Stepper(value: Binding(get: { d.min_signal ?? -82 }, set: { v in
                data?.min_signal = v
                Task { await model.run("jc", "uplink_set", ["min_signal": v]) }
            }), in: -95 ... -60, step: 1) {
                HStack {
                    Text("Drop below")
                    Spacer()
                    Text("\(d.min_signal ?? -82) dBm").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Settings")
        } footer: {
            Text("Spread: each device and site pair sticks to one source, so logins and streams don't break, and the rest is spread by weight. One download still uses one source; several at once add up. Failover: everything uses the top working source.")
        }
    }
}

struct ShareBar: View {
    let links: [RUplinks.Link]
    private static let colors: [Color] = [Theme.accent, Color(red: 0.4, green: 0.6, blue: 1), .orange, .pink]

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(links.enumerated()), id: \.offset) { pair in
                    let i = pair.offset
                    let share = CGFloat(pair.element.share ?? 0) / 100
                    if share > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Self.colors[i % Self.colors.count])
                            .frame(width: max(0, g.size.width * share - 2))
                    }
                }
            }
        }
        .frame(height: 10)
        .padding(.vertical, 4)
    }
}

struct SourceEditor: View {
    @ObservedObject var model: RouterModel
    let link: RUplinks.Link
    let cfg: RUplinks.Cfg?
    let mode: String
    let done: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var auto = true
    @State private var weight = 50.0
    @State private var enabled = true
    @State private var confirmRemove = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Toggle("Use this source", isOn: $enabled)
                }
                if mode == "balance" {
                    Section {
                        Toggle("Weight from link speed", isOn: $auto)
                        if !auto {
                            HStack {
                                Slider(value: $weight, in: 1 ... 100, step: 1)
                                Text("\(Int(weight))").monospacedDigit().frame(width: 36)
                            }
                        }
                    } footer: {
                        Text("Shares are worked out between the working sources, e.g. 70 and 30. Automatic uses each link's current rate.")
                    }
                } else {
                    Section {
                        Button("Make this the first choice") { save(first: true) }
                    }
                }
                Section("Now") {
                    LabeledContent("State", value: link.healthy == true ? "Working" : (link.reason ?? "Down"))
                    if let s = link.ssid { LabeledContent("Network", value: s) }
                    if let s = link.signal { LabeledContent("Signal", value: "\(s) dBm") }
                    if let r = link.rate { LabeledContent("Link rate", value: "\(r) Mbit/s") }
                    if let ip = link.ip { LabeledContent("Address", value: ip) }
                    if let gw = link.gw { LabeledContent("Gateway", value: gw) }
                    LabeledContent("Interface", value: link.iface)
                }
                Section {
                    Button(cfg?.managed == true ? "Remove and disconnect" : "Remove from Junction", role: .destructive) { confirmRemove = true }
                } footer: {
                    if cfg?.managed != true {
                        Text("This connection was set up outside Junction, so removing it here only stops Junction using it; the Wi-Fi link itself stays.")
                    }
                }
            }
            .navigationTitle(link.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(first: false) } }
            }
            .onAppear {
                name = cfg?.name ?? link.title
                enabled = cfg?.enabled != false
                if let w = cfg?.weight, let n = Double(w) { auto = false; weight = n } else { auto = true }
            }
            .confirmationDialog("Remove \(link.title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task {
                        await model.run("jc", "uplink_remove", ["iface": link.iface], done: "Removed \(link.title).")
                        await done()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save(first: Bool) {
        guard let sec = cfg?.sec else { dismiss(); return }
        var args: [String: Any] = ["sec": sec, "name": name, "enabled": enabled, "weight": auto ? "auto" : String(Int(weight))]
        if first { args["first"] = true }
        Task {
            await model.run("jc", "uplink_set", args, done: "Saved.")
            await done()
            dismiss()
        }
    }
}

struct AddSourceSheet: View {
    @ObservedObject var model: RouterModel
    let radios: [RUplinks.Radio]
    let done: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var radio = ""
    @State private var scan: [RScan.Net] = []
    @State private var scanning = false
    @State private var ssid = ""
    @State private var key = ""
    @State private var name = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Radio", selection: $radio) {
                        ForEach(radios) { r in Text(r.bandLabel).tag(r.sec) }
                    }
                } footer: {
                    Text("Only radios that aren't already connected to a source are listed.")
                }
                Section {
                    Button {
                        Task { await runScan() }
                    } label: {
                        HStack { Text(scanning ? "Scanning…" : "Scan for networks"); if scanning { Spacer(); ProgressView() } }
                    }
                    .disabled(scanning || radio.isEmpty)
                    ForEach(scan.filter { ($0.s ?? "").isEmpty == false }) { n in
                        Button {
                            ssid = n.s ?? ""
                            if name.isEmpty { name = ssid }
                        } label: {
                            HStack {
                                Text(n.s ?? "").foregroundStyle(.primary)
                                if ssid == n.s { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                Spacer()
                                Text(n.g.map { "\($0) dBm" } ?? "").font(.caption).foregroundStyle(.secondary)
                                SignalBars(bars: RFmt.bars(n.g))
                            }
                        }
                    }
                } header: { Text("Network") }
                Section {
                    TextField("Network name", text: $ssid).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Password (blank if open)", text: $key)
                    TextField("What to call it", text: $name)
                }
            }
            .navigationTitle("Add a source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Connect") { Task { await add() } }
                            .disabled(radio.isEmpty || ssid.isEmpty || (!key.isEmpty && key.count < 8))
                    }
                }
            }
            .onAppear { if radio.isEmpty { radio = radios.first?.sec ?? "" } }
        }
    }

    private func runScan() async {
        scanning = true
        defer { scanning = false }
        if let o = await model.run("scan-" + radio, "scan", ["radio": radio], timeout: 20), let s = try? decodeJSON(RScan.self, o) {
            scan = s.nets ?? []
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        let r = await model.run("jc", "uplink_add", ["radio": radio, "ssid": ssid, "key": key, "name": name.isEmpty ? ssid : name],
                                done: "Connecting to \(ssid). Your Wi-Fi on that band restarts for a few seconds.", timeout: 15)
        if r != nil {
            await done()
            dismiss()
        }
    }
}

struct JunctionInstall: View {
    static let command = "wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/packages/luci-app-junction/install.sh | sh"
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            Button {
                UIPasteboard.general.string = Self.command
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }
}
