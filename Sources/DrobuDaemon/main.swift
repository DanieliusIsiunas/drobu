import Foundation
import DrobuShared

// U2 scaffold: a no-op resident daemon. U4 replaces this entry point with the
// real NSXPCListener + SleepControlService wiring (fail-closed code-sign
// requirement, watchdog, boot reconciliation, legacy sweep). Kept minimal here
// so the bundle builds, signs, and can be registered/approved before Phase B
// lands. `dispatchMain()` keeps the process resident under launchd RunAtLoad.
FileHandle.standardError.write(Data("\(DaemonConstants.daemonLabel): scaffold up (no-op)\n".utf8))
dispatchMain()
