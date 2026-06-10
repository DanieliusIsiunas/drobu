import Foundation
import LocalAuthentication

/// Outcome of the `LAContext` consent sheet.
///
/// IMPORTANT: this is **consent UX, not an authorization control**. The result
/// never reaches the daemon and is not verified daemon-side; a hostile XPC
/// client skips it entirely. The privilege boundary is the one-time BTM
/// approval plus the Team-ID-anchored XPC code-sign requirement.
enum AuthResult: Equatable, Sendable {
    case success      // Touch ID / Apple Watch / password all resolve here
    case cancelled    // user dismissed — abort silently
    case failed(String) // lockout / unavailable — surface a visible failure
}

/// Injectable seam over `LAContext` so `ClosedLidService` is testable without a
/// real biometric prompt.
protocol AuthGating: Sendable {
    func authenticate(reason: String) async -> AuthResult
}

/// Production gate. Policy `.deviceOwnerAuthentication`: Touch ID, Apple Watch,
/// and an automatic password fallback (covers clamshell-docked Macs and
/// no-Touch-ID hardware — a successful password entry returns `.success`).
struct AuthGate: AuthGating {
    func authenticate(reason: String) async -> AuthResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<AuthResult, Never>) in
            // Fresh context per evaluation (no reuse window).
            let context = LAContext()
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .success)
                    return
                }
                guard let code = (error as? LAError)?.code else {
                    continuation.resume(returning: .failed("Authentication unavailable"))
                    return
                }
                switch code {
                case .userCancel, .appCancel, .systemCancel:
                    continuation.resume(returning: .cancelled)
                default:
                    // authenticationFailed / biometryLockout / passcodeNotSet / …
                    continuation.resume(returning: .failed("Authentication failed"))
                }
            }
        }
    }
}
