import SwiftUI

/// The activation form shown inside `ActivationPanel`. Serves three states:
/// the trial-ended purchase/paste screen, the device-cap remediation screen
/// (valid key, but 3 Macs already active), and the refunded-license screen.
///
/// `licenseManager` is observed so the view reacts to status changes;
/// `onActivated` is invoked when a valid key is accepted, letting the
/// host panel close itself.
struct ActivationView: View {
    @ObservedObject var licenseManager: LicenseManager
    var onActivated: () -> Void

    @State private var keyInput: String = ""
    @State private var errorMessage: String?
    @State private var activationSucceeded: Bool = false
    @State private var isActivating: Bool = false
    @FocusState private var keyFieldFocused: Bool

    private enum Mode: Equatable {
        case purchase
        case overCap([ActivatedDevice])
        case revoked
    }

    private var mode: Mode {
        switch licenseManager.status {
        case .activationLimitReached(let devices): return .overCap(devices)
        case .licenseRevoked: return .revoked
        default: return .purchase
        }
    }

    var body: some View {
        Group {
            switch mode {
            case .purchase: purchaseView
            case .overCap(let devices): overCapView(devices)
            case .revoked: revokedView
            }
        }
        .frame(width: 480, height: 360)
        .background(.regularMaterial)
        .onAppear {
            // Defer focus until after the panel is on screen — focusing
            // synchronously during onAppear races with NSPanel key window
            // assignment.
            DispatchQueue.main.async {
                if mode == .purchase { keyFieldFocused = true }
            }
        }
    }

    // MARK: - Purchase / paste (trial ended)

    private var purchaseView: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Your 14-day trial has ended")
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Buy Drobu for $14.99 one-time, or paste a license key you already have.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .padding(.top, 16)

            Text("Buy Drobu — $14.99")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    NSWorkspace.shared.open(PurchaseLinks.buy)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Buy Drobu for $14.99")
                .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                Text("or")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            }
            .padding(.horizontal, 24)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Paste your license key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("DROBU-…", text: $keyInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .lineLimit(3...6)
                    .focused($keyFieldFocused)
                    .disabled(activationSucceeded || isActivating)
                    .onChange(of: keyInput) { _, newValue in handleKeyInput(newValue) }

                Text("Paste from clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .onTapGesture { pasteFromClipboard() }
                    .accessibilityLabel("Paste license key from clipboard and activate")
                    .accessibilityAddTraits(.isButton)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                activateButton
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Text("Paid but no key? Email \(PurchaseLinks.supportEmail) and we'll sort it out.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
        }
    }

    /// Renders the Activate button in three states: idle (gray when empty,
    /// accent-tinted when key is pasted), in-flight (verifying with the
    /// server), and post-success (green checkmark while we hold for ~1.4s
    /// before dismissing the panel).
    @ViewBuilder
    private var activateButton: some View {
        if activationSucceeded {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
                Text("Activated — welcome to Drobu")
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.green)
            )
            .accessibilityLabel("Activation successful")
        } else {
            Text(isActivating ? "Activating…" : "Activate")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(keyInput.isEmpty ? Color.secondary : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(keyInput.isEmpty ? Color.secondary.opacity(0.15) : Color.accentColor)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !keyInput.isEmpty, !isActivating else { return }
                    activate()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Activate license key")
        }
    }

    // MARK: - Device-cap remediation

    private func overCapView(_ devices: [ActivatedDevice]) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text(ActivationCopy.overCapTitle())
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(ActivationCopy.overCapMessage(deviceCount: devices.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
            .padding(.top, 18)

            if !devices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { _, device in
                        Text("• \(ActivationCopy.deviceLine(device))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(ActivationCopy.deviceLine(device))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
            }

            Text(isActivating ? "Checking…" : "Check again")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                .contentShape(Rectangle())
                .onTapGesture { recheck() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Check the device limit again")
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            Text("Need help? Email \(PurchaseLinks.supportEmail).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 14)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Refunded license

    private var revokedView: some View {
        VStack(spacing: 16) {
            Text(ActivationCopy.revokedTitle)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            Text(ActivationCopy.revokedMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text("Buy Drobu — $14.99")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(PurchaseLinks.buy) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Buy Drobu for $14.99")
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    // Keys carry no whitespace, so strip any (email line-wrapping, or a
    // Return press), then auto-activate the instant a full-shaped key is
    // present. Focus-proof paste: read straight off the clipboard rather than
    // a simulated Cmd+V (which macOS doesn't reliably route to our own window).
    private func pasteFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        keyInput = s   // handleKeyInput strips whitespace + auto-activates
    }

    private func handleKeyInput(_ newValue: String) {
        errorMessage = nil
        guard !activationSucceeded, !isActivating else { return }
        let cleaned = newValue.filter { !$0.isWhitespace }
        if cleaned != newValue {
            keyInput = cleaned   // re-triggers onChange; that pass activates
            return
        }
        if cleaned.hasPrefix("DROBU-"), cleaned.dropFirst(6).contains("."), cleaned.count >= 100 {
            activate()
        }
    }

    private func activate() {
        let cleaned = keyInput.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, !isActivating else { return }
        isActivating = true
        errorMessage = nil
        Task { @MainActor in
            defer { isActivating = false }
            let verdict: ActivationVerdict?
            do {
                verdict = try await licenseManager.activate(keyString: cleaned)
            } catch let error as LicenseError {
                errorMessage = friendlyMessage(for: error)
                return
            } catch {
                errorMessage = "Activation failed: \(error.localizedDescription)"
                return
            }
            // Branch on the returned verdict, not `status` (which an active trial
            // can mask back to .trialActive).
            switch verdict {
            case .activated, .unreachable:
                activationSucceeded = true
                errorMessage = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { onActivated() }
            case .overCap, .revoked:
                // status flips to the blocked state → `mode` shows remediation.
                errorMessage = nil
            case nil:
                break   // superseded by a newer activation
            }
        }
    }

    private func recheck() {
        guard !isActivating else { return }
        isActivating = true
        Task { @MainActor in
            defer { isActivating = false }
            // force: this is an explicit user tap — bypass the cadence throttle
            // that paces background polling, so a just-freed seat is seen now.
            await licenseManager.revalidateIfNeeded(force: true)
            if case .activated = licenseManager.status { onActivated() }
        }
    }

    private func friendlyMessage(for error: LicenseError) -> String {
        switch error {
        case .malformed:
            return "That doesn't look like a valid Drobu license key. Check the email we sent and paste the whole key."
        case .badSignature:
            return "This license key was rejected. Make sure you're pasting the full key, or contact support."
        case .publicKeyMissing:
            return "Drobu is misconfigured — the embedded verification key is missing. Please contact support."
        }
    }
}
