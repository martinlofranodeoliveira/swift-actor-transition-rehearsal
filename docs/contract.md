# Public contract — development 0.1.0

This version defines a narrow, in-memory, bounded rehearsal protocol. It implements no general workflow, scheduling or external concurrency standard.

## Construction and admission

`try Limits(...)` validates inclusive ranges:

| Field | Default | Hard maximum |
| --- | ---: | ---: |
| capacity | 2 | 64 |
| liveOperations | 16 | 128 |
| barrierWaiters | 16 | 128 |
| retainedOperationRecords | 64 | 1024 |
| terminalReceipts | 64 | 1024 |
| journalEvents | 1024 | 8192 |

Every minimum is 1. Independent smaller limits are allowed. `Rehearsal(limits:)` creates generation/count zero with an empty ledger. `admit` accepts a unique, never-reused identifier of 1–64 ASCII bytes from `[A-Za-z0-9._-]`. It atomically reserves one capacity unit, live-operation slot, barrier slot, record, future terminal receipt, and ten future journal events including admission. Invalid or exhausted admission leaves canonical snapshots unchanged. Rejection precedence is identifier, duplicate, capacity, live, waiter, record, receipt, journal, counter overflow.

`OperationToken` is an opaque value capability for this ledger. Its public id/generation/ticket are observations, not reconstructible authorization. A different ledger rejects it as `foreignToken` even if numeric fields match.

## Protocol

1. Admit token; retain a task calling `execute(token)`.
2. Await `token.registration()`. For `registered`, actual barrier table registration and the first cell installation path have occurred. For `cancelledBeforeRegistration`, no table entry was inserted and the retained cancellation completion was observed. `rejected` is an internal invariant failure, not ordinary admission exhaustion.
3. Optionally call `invalidate()` to increment generation, or request cancellation.
4. `release(token, at: .suspension)` grants/records a release and resolves the first cell.
5. If still current and not cancelled, `token.resumption()` acknowledges installation at the second gate with `waitingForCommit=true`. Otherwise it eventually reports terminal outcome with `waitingForCommit=false`.
6. Release `.commit` only after the resumption acknowledgement.
7. Join the execution task. Its returned `Receipt` is terminal acknowledgement; cleanup and capacity release already occurred.

Each token permits one execution, one registration observer and one resumption observer. Duplicate execution throws `alreadyExecuting`, even after termination. Duplicate observers throw `observerAlreadyUsed`. Observers are not cancellation-aware and must not be abandoned as an owner-cleanup strategy. Callers may omit observers they do not need. Release before the appropriate phase returns `notReady`, repeated granted releases return `alreadyReleased`, and release after termination returns `terminal`; these non-grants do not journal an event. Concurrent racing release/cancel calls have no deterministic transcript promise.

`invalidate` needs an unreserved journal position. If unavailable it throws `journalLimit` without changing generation or snapshot. All logical UInt64 increments use `addingReportingOverflow`; overflow rejects rather than wraps. Execution never commits until all of its awaits, including table removal, have been revalidated.

## Cancellation

`Task.cancel()` executes a synchronous cancellation handler that marks the token control and resolves both gate cells. No forwarding task is created. This works for an already-cancelled task, including self-cancellation before entering execute.

`cancel(token)` is application cancellation, not Swift task cancellation. It returns and retains exactly one `CancellationAcknowledgement` per record. Repeated calls return that same acknowledgement and do not change the snapshot.

| When request linearizes | Meaning |
| --- | --- |
| Before execution/registration | Completion retained; execution must still run and be joined; receipt cancelled; no waiter inserted if flag observed by registration |
| After registration, before first release | Suspended cell resolves once; cleanup then cancelled receipt, no commit |
| After resumption, before terminal decision | Second cell resolves; cancelled receipt, no commit |
| After committed terminal decision | Task cancellation cannot undo state; first application cancellation reports tooLate |
| After stale/cancelled/failed terminal decision | First application cancellation reports terminal; original receipt retained |

An unacknowledged task cancellation concurrent with commit can linearize on either side. A committed task-result acknowledgement followed by application cancellation always retains commit and reports `tooLate`. Application cancellation acknowledged as `requested` prevents a later commit. Cancellation wins over staleness at the terminal checkpoint. Internal invariant failure yields `failed` rather than a successful transition; ordinary user input errors throw fixed `LabError` codes.

## Evidence and accounting

`await snapshot()` returns an immutable Sendable value, never mutable actor-owned references. Operations sort by ASCII id, journal events retain actor-assigned sequence order. `committedCount` increments once per committed receipt; stale/cancelled/failed outcomes do not increment it. Every terminal operation releases exactly one live/capacity/waiter/future-receipt reservation. Retained record and receipt evidence remains until the whole actor is released.

`reservedReceiptSlots` counts live future receipts; `retainedReceipts` counts terminals. `reservedWaiterSlots` includes not-yet-registered operations. `registeredWaiters()` separately acknowledges the private barrier's current table size; it is not an atomic cross-actor extension of snapshot. After joining every execution it is zero.

`try snapshot.canonicalJSON()` uses Foundation JSON with sorted keys, unescaped slashes, no whitespace, no timestamps, and optional nil fields omitted. The CLI adds one LF. Integer fields are JSON integer numbers; consumers requiring exact UInt64 values must not round through floating-point. Old snapshot encodings remain unchanged by later actor mutation. Canonical byte determinism is scoped to this selected Swift/Foundation environment and acknowledged protocol, not every JSON encoder or future toolchain.

## CLI and bounded work

`actor-transition-rehearsal [--assert] [--json] [--language en|pt-BR]` runs exactly eight synthetic scenarios. `--help` and `--version` are standalone. Unknown/repeated flags and incomplete language options reject. At most 16 arguments with at most 262144 aggregate UTF-8 bytes are examined. The CLI reads no stdin, loads no input files, spawns no processes, and exposes no arbitrary workload interface. Assertions are always enabled.

Human labels are translated, but scenario ids and outcome strings are stable. JSON contains `version` and ordered `scenarios`, each with `name` and `snapshot`. Success is exit 0; failures exit 1 and emit `error: CODE` on stderr. Foreign error descriptions and supplied identifiers are not echoed. Human/JSON report generation has fixed scenario count, at most two execution tasks per scenario and at most sixteen retained handles in the scenario owner. The package gate bounds each tool's combined output to 1 MiB, source files to 256 KiB each, manifest to 64 entries/16 KiB, and package uncompressed data to 64 MiB.

No internal Swift watchdog is implemented. A hung/incomplete observation is not a successful scenario or fairness/liveness result. External timeouts and resource-limit deaths fail the gate. No allocator-failure recovery, disk persistence, crash atomicity or universal cleanup guarantee is provided.
