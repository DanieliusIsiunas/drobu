import Foundation

/// One activated device on a license, for the over-cap remediation UI and the
/// Settings device list. Persisted (JSON) so the list renders offline.
public struct ActivatedDevice: Codable, Equatable, Sendable {
    public let name: String
    public let activatedAt: Date

    public init(name: String, activatedAt: Date) {
        self.name = name
        self.activatedAt = activatedAt
    }
}

/// Server verdict for an activation/re-validation attempt.
///
/// `unreachable` is the fail-open signal (KTD5/R6): a network/backend failure,
/// NOT a negative answer. The caller must never downgrade an existing grant on
/// `unreachable` — only `overCap`/`revoked` block.
public enum ActivationVerdict: Equatable, Sendable {
    case activated(email: String?)
    case overCap(devices: [ActivatedDevice])
    case revoked
    case unreachable
}

/// Talks to the activate-device Edge Function. Behind a protocol so
/// `LicenseManager` is unit-tested with canned verdicts (no network).
public protocol DeviceActivationClient: Sendable {
    func activate(key: String, deviceHash: String, deviceName: String) async -> ActivationVerdict
    /// Returns true only when the server CONFIRMED the seat was freed (HTTP 200).
    /// A network/non-200 failure returns false so the caller can keep the local
    /// license and let the user retry, rather than discarding state while the
    /// server row stays active.
    func deactivate(key: String, deviceHash: String) async -> Bool
}

/// The activate-device function endpoints. Public by design (verify_jwt=false);
/// the Ed25519 signature check inside the function is the auth.
public enum ActivationEndpoint {
    static let base = URL(
        string: "https://pslciugnzavtjksjrwzj.supabase.co/functions/v1/activate-device"
    )!
    static let activate = base
    static let deactivate = base.appendingPathComponent("deactivate")
}

/// Production client. Any transport/decoding failure maps to `.unreachable` so
/// the gate fails open — the function NEVER throws into the license state.
public struct HTTPDeviceActivationClient: DeviceActivationClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func activate(key: String, deviceHash: String, deviceName: String) async -> ActivationVerdict {
        await post(
            ActivationEndpoint.activate,
            body: ["key": key, "deviceHash": deviceHash, "deviceName": deviceName]
        )
    }

    public func deactivate(key: String, deviceHash: String) async -> Bool {
        await postExpectingOK(
            ActivationEndpoint.deactivate,
            body: ["key": key, "deviceHash": deviceHash]
        )
    }

    /// POST that only cares whether the server returned 200. Transport failure
    /// or any non-200 → false (the seat was NOT confirmed freed).
    private func postExpectingOK(_ url: URL, body: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return false }
        request.httpBody = payload
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            Log.error("DeviceActivationClient: deactivate request to \(url.lastPathComponent) failed — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Wire

    private struct DeviceDTO: Decodable {
        let device_name: String?
        let activated_at: String
    }
    private struct VerdictDTO: Decodable {
        let status: String
        let activeDevices: [DeviceDTO]?
        let email: String?
    }

    // Two formatters: `.withFractionalSeconds` makes sub-second digits REQUIRED,
    // so it rejects a whole-second timestamp; the plain one rejects fractional
    // digits. Postgres timestamptz can emit either (`…:00Z` or `…:00.123456+00:00`),
    // so we try fractional first, then plain. (ISO8601DateFormatter is documented
    // thread-safe for concurrent parsing; nonisolated(unsafe) silences the Swift 6
    // global-state check for these read-only shared formatters.)
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseActivatedAt(_ s: String) -> Date {
        isoFractional.date(from: s) ?? isoPlain.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }

    private func post(_ url: URL, body: [String: String]) async -> ActivationVerdict {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .unreachable
        }
        request.httpBody = payload

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            // 4xx/5xx (incl. a not-yet-deployed function's 404) → unreachable →
            // fail open. Only a 200 carries a real verdict.
            guard http.statusCode == 200 else {
                Log.error("DeviceActivationClient: HTTP \(http.statusCode) from \(url.lastPathComponent) — treating as unreachable")
                return .unreachable
            }
            guard let dto = try? JSONDecoder().decode(VerdictDTO.self, from: data) else {
                Log.error("DeviceActivationClient: undecodable verdict body — treating as unreachable")
                return .unreachable
            }
            switch dto.status {
            case "activated":
                return .activated(email: dto.email)
            case "over_cap":
                let devices = (dto.activeDevices ?? []).map {
                    ActivatedDevice(
                        name: $0.device_name ?? "Mac",
                        activatedAt: Self.parseActivatedAt($0.activated_at)
                    )
                }
                // An over_cap verdict always carries the (>= cap) active set. An
                // empty list is an internally-inconsistent response (partial body
                // / server bug) — fail open rather than hard-block with a
                // nonsensical "0 Macs" remediation screen.
                if devices.isEmpty {
                    Log.error("DeviceActivationClient: over_cap with empty device list — treating as unreachable")
                    return .unreachable
                }
                return .overCap(devices: devices)
            case "revoked":
                return .revoked
            default:
                Log.error("DeviceActivationClient: unknown status '\(dto.status)' — treating as unreachable")
                return .unreachable
            }
        } catch {
            // Offline, timeout, DNS, TLS — never log the key (body carries it).
            Log.error("DeviceActivationClient: request to \(url.lastPathComponent) failed — \(error.localizedDescription)")
            return .unreachable
        }
    }
}
