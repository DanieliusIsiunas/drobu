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

## `notarytool` "No Keychain password item found for profile" usually means LOCKED, not MISSING

Observed live during a v1.9.8 release (2026-07-01): `release.sh`'s notary preflight
(`xcrun notarytool history --keychain-profile "notary-profile"`) failed with:

```
Error: No Keychain password item found for profile: notary-profile
```

even though the **same profile had notarized a release hours earlier** and the user
changed nothing. Root cause: the login keychain **auto-locked on sleep** (settings show
`no-timeout`, so it doesn't lock on idle — but it *does* lock on sleep/logout). A locked
keychain returns its stored items as "not found," so notarytool reports the profile as
missing. The failure reproduces in **both** background and foreground until the keychain
is unlocked, then **self-resolves the moment the Mac is woken/unlocked** (which re-unlocks
the login keychain).

**Don't misread this as a deleted credential** (the wrong first call here — nearly sent the
user to re-run `notarytool store-credentials`). Diagnose lock-vs-missing before escalating:

```bash
# Lock test — read ANY known secret to /dev/null; rc=0 means the keychain is unlocked/readable.
security find-generic-password -w -s "com.danielius.ClipboardHistory.license-signing" \
    -a "drobu-license-ed25519" >/dev/null 2>&1; echo "rc=$?"
# Then just re-run the notarytool check — if the Mac is now awake it will succeed.
xcrun notarytool history --keychain-profile "notary-profile"
```

`security show-keychain-info` prints the lock *settings* (e.g. `no-timeout`) whether or not
the keychain is currently locked, so it is **not** a lock-state test — use the secret-read
`rc` check above. Fix is simply to have the Mac awake/unlocked (or
`security unlock-keychain ~/Library/Keychains/login.keychain-db`) and re-run `release.sh`;
the run aborts at preflight *before* any tag/build/publish, so a locked-keychain failure
leaves no partial release to clean up.
