import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("General") {
                Text("Global Hotkey: Cmd+Shift+V")
                    .foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("About") {
                Text("Clipboard History v1.0")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 200)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
