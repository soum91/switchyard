import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var asusCreds: RouterSetup.Creds? = Vault.read(RouterSetup.Creds.self, "asus")
    @Published var tpCreds: TPCreds? = Vault.read(TPCreds.self, "tplink")
    @Published private(set) var asus: RouterModel?
    @Published private(set) var tplink: TPLinkModel?
    private var active = false

    init() { rebuild() }

    func setAsus(_ c: RouterSetup.Creds?) {
        Vault.write(c, "asus")
        asusCreds = c
        rebuild()
    }

    func setTP(_ c: TPCreds?) {
        Vault.write(c, "tplink")
        tpCreds = c
        rebuild()
    }

    private func rebuild() {
        asus?.stop()
        tplink?.stop()
        asus = asusCreds.map { RouterModel(link: DirectLink(UbusClient(host: $0.host, user: $0.user, pass: $0.pass))) }
        tplink = tpCreds.map { TPLinkModel(host: $0.host, password: $0.password) }
        if active { start() }
    }

    func start() {
        active = true
        asus?.start()
        tplink?.start()
    }

    func stop() {
        active = false
        asus?.stop()
        tplink?.stop()
    }
}

@main
struct SwitchyardApp: App {
    @StateObject private var store = AppStore.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { AsusTab() }
                    .tabItem { Label("ASUS", systemImage: "wifi.router") }
                NavigationStack { TPLinkTab() }
                    .tabItem { Label("TP-Link", systemImage: "antenna.radiowaves.left.and.right") }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
        }
        .onChange(of: phase, initial: true) { _, p in
            switch p {
            case .active: store.start()
            case .background: store.stop()
            default: break
            }
        }
    }
}

struct AsusTab: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if let m = store.asus {
            RouterDashboard(model: m, title: "ASUS") { store.setAsus(nil) }
        } else {
            AsusSetupView { store.setAsus($0) }
        }
    }
}

struct TPLinkTab: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if let m = store.tplink {
            TPLinkDashboard(model: m) { store.setTP(nil) }
        } else {
            TPSetupView { store.setTP($0) }
        }
    }
}
