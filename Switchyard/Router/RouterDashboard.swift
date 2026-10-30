import SwiftUI

/// Everything for the OpenWrt router: status, the quick switches, and the deeper pages.
struct RouterDashboard: View {
    @ObservedObject var model: RouterModel
    var title: String = "Router"
    var onForget: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let e = model.error, model.status == nil || model.notInstalled {
                    errorCard(e)
                }
                if let s = model.status {
                    overview(s)
                    internet(s)
                    switches(s)
                    pages(s)
                } else if model.error == nil {
                    ProgressView().padding(.top, 60)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(model.status?.host ?? title)
        .refreshable { await model.refresh() }
        .overlay(alignment: .bottom) { RouterToast(text: model.toast) }
        .toolbar {
            if let onForget {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Forget this router", role: .destructive, action: onForget)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private func errorCard(_ e: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: "Can't reach the router", icon: "exclamationmark.triangle")
            Text(e).font(.subheadline)
            if model.notInstalled {
                Text("Run this on the router over SSH (one line), then pull to refresh:")
                    .font(.footnote).foregroundStyle(.secondary)
                InstallCommand()
            }
            Button("Try again") { Task { await model.refresh() } }
                .buttonStyle(.bordered)
        }
        .card()
    }

    private func overview(_ s: RStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: s.model ?? "Router", icon: "wifi.router")
            HStack(alignment: .top) {
                stat("Up", RFmt.uptime(s.uptime))
                stat("Devices", s.clients.map(String.init) ?? "–")
                stat("Load", s.load?.first.map { String(format: "%.2f", $0) } ?? "–")
                stat("Memory", s.memUsed.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
            }
            if let r = s.release {
                Text(r + (s.time.map { " · " + $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func internet(_ s: RStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(text: "Internet", icon: "globe")
                Spacer()
                if let u = s.up, u.signal != nil {
                    SignalBars(bars: RFmt.bars(u.signal))
                }
            }
            if let u = s.up {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(RFmt.rate(model.down), systemImage: "arrow.down").font(.title3.weight(.semibold).monospacedDigit())
                        Label(RFmt.rate(model.up), systemImage: "arrow.up").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(u.ssid.map { "via \($0)" } ?? "via \(u.iface ?? "wan")").font(.subheadline.weight(.medium))
                        Text(u.ip ?? "–").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let sig = u.signal { Text("\(sig) dBm").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if s.warp?.route == true && s.warp?.up == true {
                    Label("Traffic is going through WARP", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(Theme.good)
                }
            } else {
                Label("No upstream connection", systemImage: "xmark.octagon").foregroundStyle(Theme.bad)
            }
        }
        .card()
    }

    private func switches(_ s: RStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle(text: "Quick switches", icon: "switch.2").padding(.bottom, 6)
            if let ab = s.ab {
                SwitchRow(icon: "hand.raised.fill", title: "Ad blocking",
                          detail: adblockDetail(ab), isOn: ab.on == true && ab.paused != true,
                          busy: model.busy.contains("ab")) { on in Task { await model.setAdblock(on) } }
            }
            if let w = s.warp {
                Divider().opacity(0.4)
                SwitchRow(icon: "bolt.shield.fill", title: "WARP tunnel",
                          detail: w.up == true ? "Handshake \(RFmt.ago(w.hs))" + (w.route == true ? "" : " · not routing") : "Off",
                          isOn: w.up == true, tint: s.warpHealthy || w.up != true ? nil : Theme.bad,
                          busy: model.busy.contains("warp")) { on in Task { await model.setWarp(on) } }
            }
            if let l = s.led, (l.n ?? 0) > 0 {
                Divider().opacity(0.4)
                SwitchRow(icon: "lightbulb.fill", title: "Router lights",
                          detail: l.sch == true ? "Off \(l.offAt ?? "?") – on \(l.onAt ?? "?")" : "No schedule",
                          isOn: l.off != true, busy: model.busy.contains("led")) { on in Task { await model.setLeds(on) } }
            }
            if let n = s.nw {
                Divider().opacity(0.4)
                SwitchRow(icon: "waveform.path.ecg", title: "Drop logging",
                          detail: n.on == true ? ((n.n ?? 0) == 0 ? "No drops logged" : "\(n.n ?? 0) drop\(n.n == 1 ? "" : "s") logged") : "Off",
                          isOn: n.on == true, busy: model.busy.contains("nw")) { on in Task { await model.setNetwatch(on) } }
            }
        }
        .card()
    }

    private func adblockDetail(_ ab: RStatus.Adblock) -> String {
        if ab.paused == true && ab.on != true { return "Paused" }
        var parts: [String] = []
        if let n = ab.n, n > 0 { parts.append("\(n.formatted()) domains") }
        if let c = ab.custom, c > 0 { parts.append("\(c) of yours") }
        if ab.on != true { return parts.isEmpty ? "Off" : "Off · " + parts.joined(separator: " · ") }
        return parts.isEmpty ? (ab.state ?? "On") : parts.joined(separator: " · ")
    }

    private func pages(_ s: RStatus) -> some View {
        VStack(spacing: 0) {
            nav("Devices", "laptopcomputer.and.iphone", s.clients.map { "\($0) online" }) { ClientsView(model: model) }
            nav("Blocked sites", "nosign", nil) { BlockingView(model: model) }
            nav("Wi-Fi", "wifi", s.guest?.on == true ? "Guest on" : nil) { WifiView(model: model) }
            nav("Light schedule", "moon.stars", nil) { LedScheduleView(model: model) }
            nav("Diagnostics & logs", "stethoscope", nil) { DiagnosticsView(model: model) }
            nav("System", "cpu", nil, last: true) { SystemView(model: model) }
        }
        .padding(.vertical, 4)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
    }

    private func nav<D: View>(_ title: String, _ icon: String, _ detail: String?, last: Bool = false, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        VStack(spacing: 0) {
            NavigationLink { dest() } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).frame(width: 26).foregroundStyle(Theme.accent)
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            if !last { Divider().opacity(0.4).padding(.leading, 54) }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SwitchRow: View {
    let icon: String
    let title: String
    let detail: String
    let isOn: Bool
    var tint: Color? = nil
    let busy: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(tint ?? Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(tint ?? .secondary)
            }
            Spacer()
            if busy { ProgressView().padding(.trailing, 6) }
            Toggle("", isOn: Binding(get: { isOn }, set: { set($0) }))
                .labelsHidden()
                .disabled(busy)
        }
        .padding(.vertical, 6)
    }
}

struct RouterToast: View {
    let text: String?
    var body: some View {
        if let t = text {
            Text(t)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 20).padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct InstallCommand: View {
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(RouterSetup.installCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            Button {
                UIPasteboard.general.string = RouterSetup.installCommand
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
    }
}
