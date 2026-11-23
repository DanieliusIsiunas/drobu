# Release Pipeline (`release.sh`) Gotchas

Learned running releases from an agent session. Covers how to *run*
`release.sh`; what it checks is in `macos-distribution.md`,
`sparkle-macos-gotchas.md`, and `keychain-and-crypto.md` (notarytool).

## `release.sh` has an interactive `Continue? [y/N]` gate — non-interactive runs abort silently

After its preflight checks and the "About to release:" summary, `release.sh`
stops at:

```bash
read -rp "Continue? [y/N] " yn
```

Run without a terminal on stdin (an agent's background Bash, `nohup`, CI,
`< /dev/null`), `read` hits EOF and returns non-zero. Under `set -e` that exits
the script **immediately with status 1**, so the `|| { echo "Aborted."; exit 1; }`
branch never runs and no "Aborted." line is printed. The log just ends after
`From SHA: …`, which looks like a hang or a crash, not a declined prompt.
(Observed on the v1.12.2 release, 2026-11-23.)

It's harmless: the gate sits **before** the build, so nothing is built,
notarized, tagged, or published. Re-run without cleaning anything up.

**How to run it from an agent once the user has approved the release in chat:**

```bash
echo y | ./release.sh > <scratchpad>/release-X.Y.Z.log 2>&1; echo "exit=$?"
```

- That prompt is the human go/no-go. Pipe `y` only after the user has explicitly
  asked for this release, never to get past it on your own initiative.
- Run it in the background: two notarizations plus the Pages-propagation poll
  take ~5–10 minutes.
- With the `; echo "exit=$?"` wrapper, the background task always reports exit
  code 0. Read the `exit=` line, and check the log for
  `✓ Released vX.Y.Z — published AND verified end-to-end`.
- A clean run prints a few `! … Pages still serving <old> — propagation` lines
  during post-publish verification. That's expected; the poll waits for the
  GitHub Pages deploy.
