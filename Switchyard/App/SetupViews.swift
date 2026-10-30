import SwiftUI

struct AsusSetupView: View {
    let done: (RouterSetup.Creds) -> Void
    @State private var host = "192.168.1.1"
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var needsInstall = false

    var body: some View {
        Form {
            Section {
                Text("Switchyard runs your OpenWrt router (the ASUS) through a small plugin on the router. Sign in with the root password once: the router makes Switchyard its own login, and the root password isn't kept.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Router") {
                TextField("Address", text: $host)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Root password", text: $password)
            }
            if needsInstall {
                Section {
                    Text("The plugin isn't on the router yet. SSH in (ssh root@\(host)) and run this one line:")
                        .font(.footnote)
                    InstallCommand()
                } header: { Text("One-time install") }
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.bad).font(.footnote) }
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text(needsInstall ? "I ran it, try again" : "Connect"); if working { Spacer(); ProgressView() } }
                }
                .disabled(working || host.isEmpty || password.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Add the ASUS")
    }

    private func connect() async {
        working = true
        defer { working = false }
        error = nil
        do {
            let c = try await RouterSetup.provision(host: host, rootPassword: password)
            password = ""
            done(c)
        } catch RouterError.notInstalled {
            needsInstall = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TPSetupView: View {
    let done: (TPCreds) -> Void
    @State private var host = "192.168.0.1"
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Uses the TP-Link's own web login (the password you use at its admin page). Only one session at a time is allowed, so if the web page is open somewhere, log out there first.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Router") {
                TextField("Address", text: $host)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Admin password", text: $password)
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.bad).font(.footnote) }
            }
            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack { Text("Connect"); if working { Spacer(); ProgressView() } }
                }
                .disabled(working || host.isEmpty || password.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Add the TP-Link")
    }

    private func connect() async {
        working = true
        defer { working = false }
        error = nil
        let c = TPLinkClient(host: host, password: password)
        do {
            try await c.login()
            _ = try await c.status()
            await c.logout()
            done(TPCreds(host: host, password: password))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
