import Foundation

/// Customer-facing commerce endpoints, in one place.
///
/// `buy` points at the drobu.app redirect we control — never directly at
/// the Stripe Payment Link. The bare Stripe URL baked into shipped
/// binaries (v1.2–v1.5.2) is a permanent contract: never deactivate that
/// link; price changes edit it in place. New builds go through this
/// mutable indirection so the checkout target can change without
/// stranding installed apps (see docs/licensing.md).
enum PurchaseLinks {
    /// HTTPS 302 at the Cloudflare edge → the live Stripe Payment Link.
    static let buy = URL(string: "https://drobu.app/buy")!

    /// Support mailbox shown in the activation panel footer and docs.
    static let supportEmail = "support@drobu.app"
}
