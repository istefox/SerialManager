import SwiftUI

/// The serial with Show/Hide and Copy. Masked by default.
struct SerialRow: View {
    let lookup: LicenseStore.SerialLookup
    @Binding var isRevealed: Bool
    var showsCopied = false
    var onCopy: () -> Void = {}
    var onAddSerial: (() -> Void)?

    /// Fixed length, so the real length of the serial is not leaked.
    static let mask = String(repeating: "\u{2022}", count: 12)

    var body: some View {
        switch lookup {
        case .loading:
            LabeledContent("Serial") {
                ProgressView().controlSize(.small)
            }
        case .present(let serial):
            LabeledContent("Serial") {
                HStack(spacing: 8) {
                    serialText(serial)
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Label(isRevealed ? "Hide Serial" : "Show Serial",
                              systemImage: isRevealed ? "eye.slash" : "eye")
                    }
                    .labelStyle(.iconOnly)
                    .help(isRevealed ? Text("Hide Serial") : Text("Show Serial"))
                    Button { onCopy() } label: {
                        Label(showsCopied ? "Copied" : "Copy",
                              systemImage: showsCopied ? "checkmark" : "doc.on.doc")
                    }
                    .help(Text("Copy Serial"))
                    .accessibilityLabel(Text("Copy Serial"))
                }
                .buttonStyle(.borderless)
            }
        case .missing:
            LabeledContent("Serial") {
                VStack(alignment: .trailing, spacing: 6) {
                    Label("The serial for this license is missing from the Keychain.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.trailing)
                    if let onAddSerial {
                        Button("Add Serial\u{2026}") { onAddSerial() }
                    }
                }
            }
        case .failed(let message):
            LabeledContent("Serial") {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private func serialText(_ serial: String) -> some View {
        if isRevealed {
            Text(verbatim: serial)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } else {
            Text(verbatim: Self.mask)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Hidden"))
        }
    }
}

#if DEBUG
private struct SerialRowPreview: View {
    let lookup: LicenseStore.SerialLookup
    @State var isRevealed: Bool
    var showsCopied = false

    var body: some View {
        Form {
            SerialRow(lookup: lookup, isRevealed: $isRevealed, showsCopied: showsCopied, onAddSerial: {})
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

#Preview("Serial, masked") { SerialRowPreview(lookup: .present("ACME-0000-TEST-0000"), isRevealed: false) }
#Preview("Serial, revealed") { SerialRowPreview(lookup: .present("ACME-0000-TEST-0000"), isRevealed: true) }
#Preview("Serial, long revealed") {
    SerialRowPreview(lookup: .present("FAKE-KEY-ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ00-0000"), isRevealed: true)
}
#Preview("Serial, copied") {
    SerialRowPreview(lookup: .present("ACME-0000-TEST-0000"), isRevealed: false, showsCopied: true)
}
#Preview("Serial, missing") { SerialRowPreview(lookup: .missing, isRevealed: false) }
#Preview("Serial, loading") { SerialRowPreview(lookup: .loading, isRevealed: false) }
#Preview("Serial, error") { SerialRowPreview(lookup: .failed("Keychain error (sample)."), isRevealed: false) }
#endif
