import SwiftUI

/// The activation form shown inside `ActivationPanel` once the trial
/// has expired. Three actions: buy, paste-and-activate, dismiss.
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
    @FocusState private var keyFieldFocused: Bool

    private static let stripeURL = URL(string: "https://buy.stripe.com/14A7sL2rkeKx6sj3QNdnW01")!
    private static let supportEmail = "support@drobu.app"

    var body: some View {
        VStack(spacing: 18) {
            // Headline + sub
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

            // Buy button
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
                    NSWorkspace.shared.open(Self.stripeURL)
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Buy Drobu for $14.99")
                .padding(.horizontal, 24)

            // Divider with "or"
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                Text("or")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            }
            .padding(.horizontal, 24)

            // Paste license key — multi-line so the full ~110-char key
            // is visible at a glance and the user can confirm they
            // pasted it correctly.
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste your license key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("DROBU-…", text: $keyInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3, reservesSpace: true)
                    .focused($keyFieldFocused)
                    .disabled(activationSucceeded)
                    .onChange(of: keyInput) { _, _ in errorMessage = nil }
                    .onSubmit(activate)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                activateButton
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)

            // Footer: support contact
            Text("Already paid? Email \(Self.supportEmail) — we'll send your key.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
        .frame(width: 480, height: 360)
        .background(.regularMaterial)
        .onAppear {
            // Defer focus until after the panel is on screen — focusing
            // synchronously during onAppear races with NSPanel key window
            // assignment.
            DispatchQueue.main.async {
                keyFieldFocused = true
            }
        }
    }

    /// Renders the Activate button in three states: idle (gray when empty,
    /// accent-tinted when key is pasted), and post-success (green
    /// checkmark while we hold for ~1.4s before dismissing the panel —
    /// silent close was reading as "did anything happen?").
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
            Text("Activate")
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
                    guard !keyInput.isEmpty else { return }
                    activate()
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Activate license key")
        }
    }

    private func activate() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try licenseManager.activate(keyString: trimmed)
            // Show success briefly so the user sees confirmation —
            // closing the panel immediately reads as "did anything
            // happen?" and is the #1 complaint pattern in indie apps.
            activationSucceeded = true
            errorMessage = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                onActivated()
            }
        } catch let error as LicenseError {
            errorMessage = friendlyMessage(for: error)
        } catch {
            errorMessage = "Activation failed: \(error.localizedDescription)"
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
