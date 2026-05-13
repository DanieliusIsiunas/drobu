# Keychain & Crypto on macOS

## LibreSSL ships without Ed25519

macOS bundles LibreSSL 3.x as the system `openssl`. Its `genpkey` doesn't support Ed25519:

```bash
$ openssl genpkey -algorithm ED25519 -out priv.pem
Algorithm ED25519 not found
```

This breaks any shell script that assumes "openssl can do everything modern." Avoid the trap by either:

1. **Use Homebrew openssl** (paths: `/opt/homebrew/opt/openssl/bin/openssl` or `openssl@3`). Heavier dep but full algorithm support.
2. **Use Swift's `CryptoKit` inline via `swift -e`** — preferred when the resulting key is verified by a Swift app anyway. Example from `tools/generate-license-keypair.sh`:
   ```bash
   KEYPAIR=$(swift -e '
   import CryptoKit
   let priv = Curve25519.Signing.PrivateKey()
   print(priv.rawRepresentation.base64EncodedString())
   print(priv.publicKey.rawRepresentation.base64EncodedString())
   ')
   PRIV_B64=$(echo "$KEYPAIR" | sed -n '1p')
   PUB_B64=$(echo "$KEYPAIR" | sed -n '2p')
   ```

Option 2 has the bonus that bytes are guaranteed byte-compatible with the app's verifier (same framework, no encoding-version drift).

Same pattern works for signing operations from shell:
```bash
SIG_B64URL=$(swift -e "
import CryptoKit; import Foundation
let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: \"$PRIV_B64\")!)
let sig = try priv.signature(for: payloadData)
print(sig.base64EncodedString())
")
```

## Storing private keys in Keychain via `security`

`security add-generic-password` is the standard incantation for shell-managed private keys. Pattern:

```bash
security add-generic-password \
    -a "drobu-license-ed25519" \
    -s "com.danielius.ClipboardHistory.license-signing" \
    -w "$PRIV_B64" \
    -j "Description of what this key signs and when it was generated" \
    -U
```

- `-a` (account) and `-s` (service) form the unique lookup key — pick app-specific values to avoid collisions
- `-w` accepts the password/secret directly. **Never** pass a private key on the command line where shell history can capture it; here `$PRIV_B64` is set from a subprocess and is destroyed at script exit
- `-j` is a human-readable comment that shows in Keychain Access (helps future-you understand what the entry is for)
- `-U` updates the entry if it already exists rather than failing

Read back with `security find-generic-password -a <account> -s <service> -w`.

Always include a check before generating a new keypair:
```bash
if security find-generic-password -a "$ACCOUNT" -s "$SERVICE" >/dev/null 2>&1; then
    echo "Key already exists — refusing to clobber. Pass --force to override."
    exit 1
fi
```

Clobbering a signing key invalidates every certificate / signature / license that depends on it.

## Keychain access from subprocesses

The login Keychain is normally unlocked for processes spawned by the logged-in user, but subprocesses launched via certain mechanisms (some launchd flavors, ssh, scheduled tasks) may see it as locked. If `security find-generic-password` returns `errSecItemNotFound` or `errSecUserCanceled`, the keychain may need explicit unlocking:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

This prompts the user for the login password and is unsuitable for unattended automation. For unattended use (e.g., a CI runner signing builds), use a dedicated keychain with a stored password instead of relying on the login keychain.
