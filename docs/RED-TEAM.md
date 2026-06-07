# How this was built — and broken, and fixed

This tool moves real data with `rsync --delete`. So before it ever touched a real vault, the design and then the scripts went through five rounds of adversarial review — each round a fan-out of independent reviewer agents, with the serious findings cross-examined by separate "refuter" agents before any fix was accepted. This document is the honest record. It is the author's own multi-agent review process — not an external audit.

The short version: **document review made the design look clean after four rounds. Then a round that actually *ran attacks* found a critical bug in an hour.** That contrast is the most important lesson here.

## Round 1 — design review (27 findings)

Four reviewer lenses (safety, consistency, ambiguity, requirements) over the written spec. The big ones:

- **Deletions wouldn't propagate.** The first design mirrored on file-write events — but deleting a memory file isn't a write event, so deleted memory would have lingered in the vault forever. Fix: reconcile on session boundaries, not just writes.
- **GNU vs BSD rsync.** The spec assumed GNU `rsync`; macOS 15+ ships Apple's **openrsync**, with different `--delete` semantics and exit codes. Caught by probing the real binary.

## Round 2 — the cry-wolf bug

The drift mechanism, as first built, would have logged **every routine memory save as "drift"** — because a normal `memory → vault` update also makes source and destination differ. The genuine "someone edited the vault" signal would have drowned in false alarms. Fix: the checksum **manifest**, which distinguishes "what the system last wrote" from "what something else changed." This is now the heart of the design.

## Round 3 — convergence

A verification round: independent readers re-checked the rewritten design cold for internal contradictions and confirmed each prior finding was actually resolved (not just acknowledged). It caught a class of wording bugs where the spec *claimed* a stronger guarantee than the mechanism delivered — e.g. a drift report described as surfacing "the same session it is found" when the mechanics only supported "the next session start." Unglamorous, but it's how the invariants and the implementation were kept honest with each other before any code existed.

## Round 4 — the exit code that doesn't exist

A guard treated `rsync` exit code **24** ("some files vanished") as benign — a real, documented GNU rsync behavior. Except the pinned binary is **openrsync**, whose only exit codes are `0`, `1`, `2`. The "tolerate 24" branch was guarding against something that can never happen, and real concurrency tolerance had to be rebuilt around the lock instead. A finding you only get by reading the actual binary's manual.

## Round 5 — the live red-team (the one that matters)

29 agents, this time firing at the *built scripts*, not the document — each running real attack scenarios in disposable sandboxes, trying to break four invariants: one-way flow, the vault never winning, drift always surfaced, ownership boundaries held.

It found a **critical destination-escape**:

> The destination guard resolved the *parent* directory (`<vault>/Claude`) and appended the literal string `/Memory`. It never checked whether `Memory` itself was a symlink. So if something replaced `Claude/Memory` with a symlink pointing elsewhere, the exact-path check still passed — and `rsync -a --delete` would **follow that symlink and delete whatever lived at the target**, outside the vault entirely. The red-team proved it by destroying files in a sandbox directory outside the "vault."

This is exactly the threat model the tool exists for ("someone changed the mirror"), and a directory symlink at the mirror root is precisely such a change. The fix is guard **4b**: refuse outright if `Claude/Memory` is a symlink or not a directory. It's covered by a regression test ([test 4 in `tests/run-tests.sh`](../tests/run-tests.sh)) that asserts outside data survives.

A later audit found the *racing* version of the same bug: guard 4b runs ~65 lines before the `rsync`, so a hostile writer could swap the leaf to a symlink *between* the check and the copy (a TOCTOU window). The mitigation is a second leaf re-check in the few syscalls immediately before `rsync` (shrinking the window from milliseconds to microseconds) plus a documented assumption that the vault lives on local storage not shared with untrusted writers — pure shell can't fully close a check-then-use race. Covered by test 19.

The same round found three majors, all fixed and tested:
- A drift report could be **permanently silenced** if the log was ever rotated/truncated (a stale byte-offset). Fixed by switching to a drain-to-archive model with no offset at all.
- A held lock could make the "guaranteed" session-start reconciliation **silently skip**. Fixed with PID-liveness checks and a distinct exit code that the session-start hook surfaces.
- A file landing in the mirror **between drift-detection and the copy** could be erased unobserved (a TOCTOU window). Fixed by guard 6b.

The refuter panels also *rejected* several plausible-but-wrong findings — adversarial review needs adversarial filtering too, or you waste effort "fixing" non-bugs.

## The takeaways

1. **Reading a design finds design bugs. Running it finds real ones.** Four clean document rounds; one execution round found a critical. For anything touching real data, verification must execute.
2. **Design for misbehavior, not just mistakes.** Even when an agent ignored its sandbox-only instructions during the build and ran a real sync, it was harmless — because the *architecture* (one-way flow) made it harmless. Rules get broken; invariants don't.
3. **Verify the actual environment.** The openrsync findings existed only because someone read the real binary, not the assumed one.

If you find something these rounds missed: that's what the issue tracker is for. This document will grow.
