import SwiftUI
import HotKey
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotkeyCombo: KeyCombo? = HotkeyDefaults.load()

    var body: some View {
        Form {
            Section("General") {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    HotkeyRecorderView(keyCombo: $hotkeyCombo)
                        .frame(width: 160, height: 24)
                }

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
        .frame(width: 420, height: 280)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
