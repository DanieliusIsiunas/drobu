#!/usr/bin/env swift
//
// clamshell-spike.swift — Spike S1 for the Touch ID Closed Lid daemon plan.
//
// QUESTION: Can a user-space (non-root) process still prevent closed-lid sleep
// on this hardware/OS by calling kPMSetClamshellSleepState on the IOPMrootDomain
// user client? If YES, the entire privileged daemon (and all auth) is
// unnecessary and the plan pivots. If NO (expected on Apple Silicon — the
// IOPMrootDomain user client now refuses non-root opens), proceed to U2.
//
// This is a THROWAWAY probe, intentionally OUTSIDE the SPM build graph
// (`swift test` never compiles it). Run it directly:
//
//     swift tools/spikes/clamshell-spike.swift
//
// MANUAL PROTOCOL (requires a human at the machine):
//   1. Put the Mac on AC power (closed-lid sleep behaves differently on battery).
//   2. Run the script. Read the IOReturn codes it prints for the OPEN and the
//      SET-DISABLE calls. A non-zero code on either (especially
//      0xe00002c1 kIOReturnNotPrivileged) means the technique is blocked
//      without root → record it and proceed to U2.
//   3. If both calls returned success, close the lid (leave the script waiting).
//      Observe whether the Mac stays awake: easiest checks are an attached
//      external display staying lit, or pinging the Mac from your phone, or
//      music continuing. Give it ~30s.
//   4. Re-open the lid, press Return in the terminal to RESTORE clamshell sleep.
//   5. Verify the setting is back: `pmset -g` should NOT show a stuck state, and
//      the Mac should sleep normally on the next lid close.
//
// RECORD THE OUTCOME (IOReturn codes + observed lid behavior + hardware/OS) in
// `.claude/rules/smappservice-daemon.md` per requirement R10.
//
// Reference: x74353/Amphetamine-Enhancer CDMManager (the user-space clamshell
// technique); IOPMrootDomain RootDomainUserClient external-method selectors.

import Foundation
import IOKit

// Selector index into the IOPMrootDomain user client's external methods.
// From XNU RootDomainUserClient: kPMSetClamshellSleepState is selector 11.
// (kPMSetAggressiveness=0, …, kPMActivityTickle=10, kPMSetClamshellSleepState=11.)
// Not exposed in the public Swift IOKit overlay, so it is spelled out here.
let kPMSetClamshellSleepState: UInt32 = 11

// Scalar input semantics for RootDomainUserClient::setClamshellSleepState:
//   1 → DISABLE clamshell sleep (Mac stays awake with the lid closed)
//   0 → re-enable (normal behavior)
let kDisableClamshellSleep: UInt64 = 1
let kEnableClamshellSleep: UInt64 = 0

func describe(_ ret: kern_return_t) -> String {
    let code = UInt32(bitPattern: ret)
    switch code {
    case 0x0000_0000: return "kIOReturnSuccess (0) — call accepted"
    case 0xe000_02c1: return "kIOReturnNotPrivileged (0xe00002c1) — needs root/entitlement → BLOCKED user-space"
    case 0xe000_02c2: return "kIOReturnBadArgument (0xe00002c2)"
    case 0xe000_02bc: return "kIOReturnError (0xe00002bc) — generic"
    case 0xe000_02c7: return "kIOReturnUnsupported (0xe00002c7) — selector/userclient not supported"
    case 0xe000_02d8: return "kIOReturnNotPermitted (0xe00002d8)"
    case 0xe000_02be: return "kIOReturnNoMemory (0xe00002be)"
    default: return String(format: "IOReturn 0x%08x (%d)", code, ret)
    }
}

func openRootDomainConnection() -> (service: io_service_t, connect: io_connect_t)? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else {
        print("✗ IOServiceGetMatchingService(IOPMrootDomain) returned IO_OBJECT_NULL — root domain not found")
        return nil
    }
    var connect: io_connect_t = IO_OBJECT_NULL
    let openResult = IOServiceOpen(service, mach_task_self_, 0, &connect)
    print("• IOServiceOpen(IOPMrootDomain): \(describe(openResult))")
    guard openResult == KERN_SUCCESS else {
        IOObjectRelease(service)
        return nil
    }
    return (service, connect)
}

func setClamshellSleep(_ connect: io_connect_t, disabled: Bool) -> kern_return_t {
    var input = disabled ? kDisableClamshellSleep : kEnableClamshellSleep
    return IOConnectCallScalarMethod(connect, kPMSetClamshellSleepState, &input, 1, nil, nil)
}

print("=== Clamshell-sleep user-space spike (S1) ===")
print("euid=\(geteuid()) (0 = root). This probe is meaningful run as a NORMAL user.")
print("")

guard let (service, connect) = openRootDomainConnection() else {
    print("")
    print("RESULT: could not open the IOPMrootDomain user client → user-space technique is BLOCKED.")
    print("This is the expected Apple-Silicon outcome. Proceed to U2 (build the daemon).")
    exit(1)
}
defer {
    IOServiceClose(connect)
    IOObjectRelease(service)
}

let disableResult = setClamshellSleep(connect, disabled: true)
print("• Set DISABLE clamshell sleep: \(describe(disableResult))")
print("")

if disableResult != KERN_SUCCESS {
    print("RESULT: the disable call was rejected → user-space technique is BLOCKED.")
    print("Record the code above. Proceed to U2 (build the daemon).")
    exit(1)
}

print("RESULT (provisional): the call was ACCEPTED user-space. Now confirm BEHAVIOR:")
print("  1. Ensure you are on AC power.")
print("  2. Close the lid. Watch an external display / ping from phone for ~30s.")
print("  3. Re-open the lid, come back here, and press Return to RESTORE.")
print("")
print("If the Mac STAYED AWAKE lid-closed → S1 SUCCEEDS → PIVOT (no daemon needed).")
print("If the Mac SLEPT anyway → the call is a no-op on this HW → proceed to U2.")
print("")
print("Press Return to restore clamshell sleep and exit…")
_ = readLine()

let restoreResult = setClamshellSleep(connect, disabled: false)
print("• Restore (re-enable) clamshell sleep: \(describe(restoreResult))")
if restoreResult != KERN_SUCCESS {
    print("⚠️  Restore did not return success — verify with `pmset -g` and reboot if the Mac won't sleep on lid close.")
}
print("Done. Record IOReturn codes + observed lid behavior + hardware/OS in .claude/rules/smappservice-daemon.md")
