import SwiftUI
import HotKey
import ServiceManagement

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotkeyCombo: KeyCombo? = HotkeyDefaults.load()
    @State private var captureHotkeyCombo: KeyCombo? = CaptureHotkeyDefaults.load()
    @State private var retentionDays = RetentionDefaults.loadRetentionDays()
    @State private var maxItemCount = RetentionDefaults.loadMaxItemCount()

    var body: some View {
        Form {
            Section("General") {
                HStack {
                    Text("Global Hotkey")
                    Spacer()
                    HotkeyRecorderView(keyCombo: $hotkeyCombo)
                        .frame(width: 160, height: 24)
                }

                HStack {
                    Text("Capture Hotkey")
                    Spacer()
                    HotkeyRecorderView(keyCombo: $captureHotkeyCombo, saveAction: CaptureHotkeyDefaults.save)
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

            Section("Storage & Retention") {
                HStack(spacing: 8) {
                    Text("Keep items for")
                    Spacer()
                    TextField("", value: $retentionDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .onChange(of: retentionDays) { _, newValue in
                            let clamped = max(1, min(365, newValue))
                            if clamped != newValue {
                                retentionDays = clamped
                            }
                            RetentionDefaults.save(retentionDays: retentionDays, maxItemCount: maxItemCount)
                        }
                    Text("days")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                HStack(spacing: 8) {
                    Text("Maximum items")
                    Spacer()
                    TextField("", value: $maxItemCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onChange(of: maxItemCount) { _, newValue in
                            let clamped = max(100, min(50000, newValue))
                            if clamped != newValue {
                                maxItemCount = clamped
                            }
                            RetentionDefaults.save(retentionDays: retentionDays, maxItemCount: maxItemCount)
                        }
                    Text("items")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                Text("Items older than the retention period or beyond the maximum count will be automatically deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("About") {
                Text("Clipboard History v1.0")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            retentionDays = RetentionDefaults.loadRetentionDays()
            maxItemCount = RetentionDefaults.loadMaxItemCount()
        }
    }
}
