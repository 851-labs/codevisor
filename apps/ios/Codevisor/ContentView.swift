// Smoke-test view: importing ACPKit/CodevisorTheming/CodevisorCore proves the
// shared CodevisorKit package (apps/macos/Packages) builds and links for iOS,
// and the health check proves the app can reach the dev remote server started
// by `bun run dev:ios` (which passes the server's coordinates via the launch
// environment).
import ACPKit
import CodevisorCore
import CodevisorTheming
import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    private enum ServerStatus: Equatable {
        case unconfigured
        case checking(String)
        case healthy(String)
        case unreachable(String)
    }

    @State private var status = ServerStatus.unconfigured

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward.inward")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Codevisor iOS")
                .font(.title.bold())
            Text("Scaffold booted — shared CodevisorKit linked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("AppEnvironment ready — \(appEnvironment.machines.machines.count) machine(s), no local server: \(appEnvironment.localServer == nil ? "✓" : "✗")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            statusLabel
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task { await checkServer() }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .unconfigured:
            Label("No dev server configured — launch with `bun run dev:ios`.",
                  systemImage: "bolt.slash")
                .foregroundStyle(.secondary)
        case .checking(let address):
            Label("Checking dev server at \(address)…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .healthy(let address):
            Label("Connected to dev server at \(address)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unreachable(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func checkServer() async {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["CODEVISOR_DEV_SERVER_URL"],
              let baseURL = URL(string: address) else {
            status = .unconfigured
            return
        }
        status = .checking(address)
        do {
            let (_, response) = try await URLSession.shared.data(
                from: baseURL.appending(path: "v1/health")
            )
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                status = .healthy(address)
            } else {
                status = .unreachable("Dev server at \(address) responded unexpectedly.")
            }
        } catch {
            status = .unreachable("Dev server at \(address) is unreachable: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView()
        .environment(AppEnvironment.preview())
}
