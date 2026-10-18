import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: TVSessionModel
    @AppStorage("autoScan") private var autoScan = true
    @State private var showingDevices = false
    @State private var scannedOnLaunch = false

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        deviceCard
                        if let error = session.lastError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if session.isPairing {
                            Button {
                                showingDevices = true
                            } label: {
                                Label("Enter pairing code shown on TV", systemImage: "number.square.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(14)
                                    .foregroundStyle(.white)
                                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        RemotePanel()
                        AppsPanel()
                    }
                    .padding(18)
                    .padding(.bottom, 24)
                }
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("CastDeck")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingDevices = true
                        } label: {
                            Image(systemName: "tv")
                        }
                        .accessibilityLabel("Choose a TV")
                    }
                }
            }
            .tabItem { Label("Remote", systemImage: "remote.gen3.fill") }

            SettingsPanel()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showingDevices) {
            DevicePanel().environmentObject(session)
        }
        .onAppear {
            guard !scannedOnLaunch else { return }
            scannedOnLaunch = true
            if autoScan { session.scan() }
        }
    }

    private var deviceCard: some View {
        Button { showingDevices = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "tv.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.selected?.name ?? "Choose your Google TV")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(session.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if session.isConnecting || session.isScanning {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select TV. " + session.status)
    }
}