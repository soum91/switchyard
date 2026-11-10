import SwiftUI

@MainActor
final class TPLinkModel: ObservableObject {
    let client: TPLinkClient
    @Published var status: TPStatus?
    @Published var firmware: TPFirmware?
    @Published var wifi: [TPWifi] = []
    @Published var leds: Bool?
    @Published var ledsSupported = true
    @Published var error: String?
    @Published var busy: Set<String> = []
    @Published var toast: String?
    @Published var report: String?
    @Published var diagnosing: String?
    private var poller: Task<Void, Never>?

    init(host: String, password: String, username: String? = nil) { client = TPLinkClient(host: host, password: password, username: username) }

    func start() {
        poller?.cancel()
        poller = Task { [weak self] in
            await self?.refresh()
            await self?.loadExtras()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    func stop() { poller?.cancel(); poller = nil }

    func refresh() async {
        do {
            status = try await client.status()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadExtras() async {
        firmware = try? await client.firmware()
        await loadWifi()
        do { leds = try await client.leds() } catch { ledsSupported = false }
    }

    func loadWifi() async {
        var out: [TPWifi] = []
        for f in ["wireless_2g", "wireless_5g", "guest_2g", "guest_5g"] {
            if let w = try? await client.wifi(f), w.ssid != nil || w.enabled != nil { out.append(w) }
        }
        wifi = out
    }

    func diagnose() async {
        diagnosing = "Logging in…"
        stop()
        defer { start() }
        let r = await client.diagnose { [weak self] p in self?.diagnosing = p }
        diagnosing = nil
        report = r
    }

    func say(_ t: String) {
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == t { toast = nil }
        }
    }

    func act(_ key: String, done: String, _ work: () async throws -> Void) async {
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await work()
            say(done)
        } catch {
            say(error.localizedDescription)
        }
    }
}

struct TPLinkDashboard: View {
    @ObservedObject var model: TPLinkModel
    var onForget: () -> Void
    @State private var editing: TPWifi?
    @State private var confirmReboot = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let e = model.error, model.status == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        CardTitle(text: "Can't reach the TP-Link", icon: "exclamationmark.triangle")
                        Text(e).font(.subheadline)
                        Button("Try again") { Task { await model.refresh() } }.buttonStyle(.bordered)
                    }
                    .card()
                }
                if let s = model.status {
                    overview(s)
                    wifiCard()
                    clientsCard(s)
                    actions()
                } else if model.error == nil {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(model.firmware?.model ?? "TP-Link")
        .refreshable { await model.refresh(); await model.loadWifi() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await model.diagnose() } } label: { Label("Diagnose this router", systemImage: "stethoscope") }
                        .disabled(model.diagnosing != nil)
                    Button("Forget this router", role: .destructive, action: onForget)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $editing) { w in TPWifiEditor(model: model, wifi: w) }
        .sheet(isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } })) {
            DiagnosticReportView(title: "TP-Link diagnosis", report: model.report ?? "", filename: "switchyard-tplink-diagnosis.txt")
        }
        .overlay {
            if let d = model.diagnosing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(d).font(.footnote).multilineTextAlignment(.center)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(30)
            }
        }
        .confirmationDialog("Reboot the TP-Link?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) {
                Task { await model.act("reboot", done: "Rebooting. Give it two minutes.") { try await model.client.reboot() } }
            }
        }
    }

    private func overview(_ s: TPStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: model.firmware?.model ?? "TP-Link", icon: "wifi.router")
            HStack {
                stat("CPU", s.cpu.map { pct($0) } ?? "–")
                stat("Memory", s.mem.map { pct($0) } ?? "–")
                stat("Devices", "\(s.clients.count)")
            }
            VStack(alignment: .leading, spacing: 3) {
                if let ip = s.wanIP, ip != "0.0.0.0" { row("Internet address", ip) }
                if let gw = s.wanGateway, gw != "0.0.0.0" { row("Gateway", gw) }
                if let lan = s.lanIP { row("Router address", lan) }
                if let fw = model.firmware?.firmware { row("Firmware", fw) }
            }
            .font(.caption)
        }
        .card()
    }

    /// TP-Link reports usage as 0-1 on some firmware and 0-100 on others.
    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v <= 1 ? v * 100 : v) }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospaced() }
    }

    private func wifiCard() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(text: "Wi-Fi", icon: "wifi").padding(.bottom, 6)
            if model.wifi.isEmpty { Text("Loading…").foregroundStyle(.secondary) }
            ForEach(model.wifi) { w in
                HStack(spacing: 12) {
                    Image(systemName: w.isGuest ? "person.2" : "wifi").frame(width: 26).foregroundStyle(Theme.accent)
                    Button { editing = w } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.ssid ?? w.title).foregroundStyle(.primary)
                            Text(w.title + (w.channel.map { " · ch \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.busy.contains(w.form) { ProgressView() }
                    Toggle("", isOn: Binding(get: { w.enabled == true }, set: { on in
                        Task {
                            await model.act(w.form, done: on ? "\(w.title) on." : "\(w.title) off.") { try await model.client.setWifi(w.form, enable: on) }
                            await model.loadWifi()
                        }
                    }))
                    .labelsHidden()
                }
                .padding(.vertical, 5)
            }
        }
        .card()
    }

    private func clientsCard(_ s: TPStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle(text: "Devices (\(s.clients.count))", icon: "laptopcomputer.and.iphone")
            ForEach(s.clients) { c in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name.isEmpty ? c.ip : c.name).lineLimit(1)
                        Text("\(c.ip) · \(c.mac)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(c.kind).font(.caption).foregroundStyle(.secondary)
                }
            }
            if s.clients.isEmpty { Text("Nothing connected.").foregroundStyle(.secondary) }
        }
        .card()
    }

    private func actions() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.ledsSupported, let on = model.leds {
                SwitchRow(icon: "lightbulb.fill", title: "Router lights", detail: on ? "On" : "Off", isOn: on, busy: model.busy.contains("led")) { v in
                    Task {
                        await model.act("led", done: v ? "Lights on." : "Lights off.") { try await model.client.setLeds(v) }
                        model.leds = (try? await model.client.leds()) ?? v
                    }
                }
                Divider().opacity(0.4)
            }
            Button(role: .destructive) { confirmReboot = true } label: {
                Label("Reboot", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
        .card()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TPWifiEditor: View {
    @ObservedObject var model: TPLinkModel
    let wifi: TPWifi
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var key = ""
    @State private var hidden = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section(wifi.title) {
                    TextField("Name", text: $ssid).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Password", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Toggle("Hidden", isOn: $hidden)
                }
            }
            .navigationTitle(wifi.ssid ?? wifi.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Save") {
                            saving = true
                            Task {
                                await model.act(wifi.form, done: "Saved. The TP-Link restarts that network.") {
                                    try await model.client.setWifi(wifi.form,
                                                                   ssid: ssid != wifi.ssid ? ssid : nil,
                                                                   key: key != (wifi.key ?? "") ? key : nil,
                                                                   hidden: hidden != (wifi.hidden == true) ? hidden : nil)
                                }
                                await model.loadWifi()
                                saving = false
                                dismiss()
                            }
                        }
                        .disabled(ssid.isEmpty || (!key.isEmpty && key.count < 8))
                    }
                }
            }
            .onAppear {
                ssid = wifi.ssid ?? ""
                key = wifi.key ?? ""
                hidden = wifi.hidden == true
            }
        }
    }
}
