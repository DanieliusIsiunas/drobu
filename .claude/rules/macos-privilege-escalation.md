# macOS Privilege Escalation Gotchas

## Authorization framework broken on macOS 26.3 (Tahoe)

`do shell script ... with administrator privileges` (via osascript or NSAppleScript) returns `-60008` (`errAuthorizationInternal`) even after the user successfully authenticates. This affects all Authorization framework code paths:
- NSAppleScript in-process
- osascript subprocess with `do shell script`
- AuthorizationExecuteWithPrivileges (dlsym)

## Working approach: `sudo -A` with custom askpass

Bypass Authorization framework entirely using `sudo -A`:
1. Write an askpass script that uses `osascript` + `display dialog` (AppKit, not Security framework)
2. Set `SUDO_ASKPASS` env var pointing to the askpass script
3. Run `sudo -A /bin/sh <command-script>`

This uses PAM (`/etc/pam.d/sudo`) instead of the Authorization framework — completely different code path that works reliably.

### Key details
- The askpass script must be `chmod 755` — sudo won't execute it otherwise
- Use `with hidden answer` in `display dialog` for password masking
- User cancel: osascript exits with `-128` in stderr
- Wrong password: sudo exit 1 with "password" in stderr
- Clean up temp scripts in `defer`
