import SwiftUI

/// Settings window (Cmd+,).
struct SettingsView: View {
    @AppStorage(ClipboardSettings.delayKey) private var clearDelay = ClipboardSettings.defaultDelay

    var body: some View {
        Form {
            Section {
                Picker("Clear Clipboard", selection: $clearDelay) {
                    Text("Never").tag(0)
                    Text("After 30 Seconds").tag(30)
                    Text("After 1 Minute").tag(60)
                    Text("After 2 Minutes").tag(120)
                }
            } footer: {
                Text("After you copy a serial, SerialManager removes it from the clipboard. Anything you copy afterwards is left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
}

#Preview("Settings, Italian") {
    SettingsView()
        .environment(\.locale, Locale(identifier: "it"))
}
#endif
