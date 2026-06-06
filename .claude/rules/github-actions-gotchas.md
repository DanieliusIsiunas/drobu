# GitHub Actions Gotchas

## SPM binary-target cache poisoning after repo rename

`actions/cache` with a key based only on `Package.resolved`'s hash will keep restoring stale `.build/` directories after a repo rename. The SPM artifacts manifest (e.g. `Sparkle.xcframework/Info.plist`) is downloaded once and cached, but its **internal path metadata is absolute** — it bakes the workspace path at the time the cache was populated. After a rename, the runner extracts the cache into the new workspace location, but artifact lookups still resolve against the old path and fail with:

```
error: XCFramework Info.plist not found at
'/Users/runner/work/<OLD-REPO-NAME>/<OLD-REPO-NAME>/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework'
```

`swift test` / `swift build` then exits non-zero before any actual tests run, so the failure isn't catching a code defect — it's just CI eating itself.

**Fix:** include the repo name in the cache key.

```yaml
- uses: actions/cache@v4
  with:
    path: .build
    key: ${{ runner.os }}-spm-${{ github.event.repository.name }}-${{ hashFiles('Package.resolved') }}
    restore-keys: ${{ runner.os }}-spm-${{ github.event.repository.name }}-
```

Day-to-day this caches normally (PRs and pushes hit the same key); a future rename invalidates the cache automatically.

**Why it's not obvious:** the cache key API encourages hashing source-of-truth files (manifests, lockfiles). The repo name isn't usually part of any build input. But SPM's binary-target unpacker treats absolute workspace paths as identity, so the cache contents depend on the workspace path even though no source file references it.

**Same pattern applies to:**
- Any toolchain that unpacks binary artifacts with absolute paths inside (Cargo, Go modules with vendored binaries, npm postinstall artifacts)
- Cache keys that mirror the SPM example above should always include `github.event.repository.name`

## Path-ignore filters on multi-purpose repos

`paths-ignore: ['website/**']` on the tests workflow means Dependabot PRs that bump npm deps (which only touch `website/`) don't run tests. That's intentional — there's no Swift code to test in those PRs — but it also means there's no CI signal on those PRs.

Since 2026-06-07 the `protect-main` ruleset makes the `test` check **required**, so these website-only PRs sit at "Expected — waiting for status" forever. They are NOT broken — merge them via the admin-bypass merge option ("Merge without waiting for requirements"). Repository admin is on the ruleset's bypass list precisely for this and for `release.sh`'s direct appcast push to main.

If you ever add a Swift dep that lives outside `website/`, the path filter is correct; Dependabot PRs touching `Package.resolved` will trigger CI normally.

## main is governed by a ruleset, not classic branch protection

Repo ruleset `protect-main` (id 17358659): require PR (0 approvals), required check `test`, block force-push, block deletion; bypass = repository admin (always). Inspect with `gh api repos/DanieliusIsiunas/drobu/rulesets/17358659`. Note `gh api .../branches/main/protection` returns 404 — that endpoint only sees classic branch protection, not rulesets; don't read the 404 as "unprotected".
