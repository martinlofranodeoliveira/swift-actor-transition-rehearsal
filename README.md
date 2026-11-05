# Actor Transition Rehearsal

**Development version 0.1.0.** An original, headless Swift concurrency lab by [Lofrano Tecnologia](https://lofranotecnologia.com.br). Real actors suspend at owned barriers. Immutable snapshots explain admission, reentrancy, cancellation and terminal acknowledgement. This is a teaching and regression tool, not a workload executor or a production isolation boundary.

Repository: https://github.com/martinlofranodeoliveira/swift-actor-transition-rehearsal

## Environment and installation

The selected environment is Linux x86_64, Swift **6.2.4**, Swift 6 language mode, from the immutable official image in `environment.json`. There are no external Swift packages and no runtime service, model, network or telemetry dependency. Build/package scripts additionally need Python 3's standard library and a cgroup-v2 Linux container. No compiler or runtime is redistributed in the source archive or CLI archive.

Separate official-artifact preparation from offline execution:

```sh
docker pull swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855
docker build --network=none --pull=false --tag atr-qualified:0.1.0 - < Dockerfile
```

Start the offline workspace, mounting only this source directory. Docker is an outer trusted harness, not available inside the container:

```sh
docker run --rm -it --pull=never --network=none --cap-drop=ALL \
  --security-opt=no-new-privileges --user=1000:1000 \
  --memory=1g --memory-swap=1g --cpus=2 --pids-limit=256 \
  --read-only --tmpfs /tmp:rw,exec,nosuid,nodev,size=805306368,uid=1000,gid=1000 \
  --mount type=bind,src="$PWD",dst=/workspace,readonly \
  atr-qualified:0.1.0 /bin/sh
```

Inside that container:

```sh
/bin/sh scripts/test-offline.sh
/bin/sh scripts/demo-offline.sh --assert
/bin/sh scripts/package.sh
```

The test gate archives an explicit file manifest, extracts it outside the checkout, tests that extracted package, builds a release CLI, installs its archive in another fresh directory, runs both documented languages, compares canonical reports, and compiles/runs an independent SwiftPM consumer. All Swift builds use `--disable-sandbox --jobs 2 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`. The CLI alone does not need Python.

The package command writes these actual distributions and their computed SHA-256 values to `/tmp/atr-artifacts`:

- `actor-transition-rehearsal-source-0.1.0.tar`: original source, tests, scripts and documentation;
- `actor-transition-rehearsal-cli-0.1.0.tar`: `bin/actor-transition-rehearsal`, MIT license, bilingual READMEs, environment and design/license notices. Requires the selected runtime; does not bundle it.

An installation within the same selected environment:

```sh
mkdir -p /tmp/atr-manual-install
tar -xf /tmp/atr-artifacts/actor-transition-rehearsal-cli-0.1.0.tar -C /tmp/atr-manual-install
cd /tmp/atr-manual-install
./bin/actor-transition-rehearsal --assert
./bin/actor-transition-rehearsal --assert --language pt-BR
./bin/actor-transition-rehearsal --assert --json
```

`/tmp` artifacts last only for that container's lifetime. The automated gate performs a separate fresh installation itself. There are no publishing or deployment commands.

## Demo

The EN installed CLI produces exactly:

```text
Actor Transition Rehearsal 0.1.0 (development)
PASS stale: stale; reservations=0
PASS capacity: committed,cancelled; reservations=0
PASS pre-cancel-task: cancelled; reservations=0
PASS suspended-cancel-task: cancelled; reservations=0
PASS resumed-cancel-task: cancelled; reservations=0
PASS application-cancel: cancelled; reservations=0
PASS commit-then-cancel: committed; reservations=0
PASS snapshot: committed; reservations=0
```

`--json` emits one canonical JSON report plus LF, with version and eight scenario snapshots. Arrays of operations are sorted by ASCII identifier, events by logical sequence, object keys lexically. No clocks, UUIDs or host paths enter these bytes. All scenarios assert even without `--assert`; the flag makes intent explicit. Unknown/duplicate options, invalid arguments, failed assertions and I/O failures exit 1 with a bounded error code. Success exits 0. No stdin or filesystem input is accepted by the CLI.

## Small library example

Use an extracted source package as a **local** SwiftPM dependency:

```swift
.package(path: "../actor-transition-rehearsal")
```

Add `.product(name: "ActorTransitionRehearsal", package: "actor-transition-rehearsal")` to the consumer target. A complete async function demonstrating stale assumptions:

```swift
import ActorTransitionRehearsal

func staleExample() async throws -> Receipt {
    let ledger = Rehearsal(limits: try Limits(capacity: 1))
    let token = try await ledger.admit("sample")
    let task = Task { try await ledger.execute(token) }
    do {
        _ = try await token.registration()
        _ = try await ledger.invalidate()
        _ = try await ledger.release(token, at: .suspension)
        return try await task.value
    } catch {
        task.cancel()
        _ = try? await task.value
        throw error
    }
}
```

The receipt is `stale`, with no commit. To commit without invalidation: acknowledge registration, release `.suspension`, await `token.resumption()`, release `.commit`, then join the task. Snapshot reads are `await ledger.snapshot()`; canonical encoding is `try snapshot.canonicalJSON()`.

## Why two gates?

Actor isolation protects data from simultaneous unsynchronized access; it does not keep assumptions true across `await`. The first barrier demonstrates generation invalidation. The second makes the interval after resumption but before commit observable and cancellable without sleeps. A synchronous mutex-protected cell handles cancellation before **or** after continuation installation; no cancellation-forwarding task is launched.

Admissions reserve capacity, waiter, record, future receipt and ten journal slots before any suspension. Rejections do not mutate canonical snapshots. Terminal evidence is retained, not evicted. A first late application cancellation has a reserved journal slot and cannot roll back a committed count.

See [contract](docs/contract.md), [design and Swift memory model](docs/design.md), [numeric bounds and build evidence](docs/build-notes.md), and [Portuguese documentation](README.pt-BR.md).

## Limits and non-goals

- Maximum capacity 64, live operations/waiter slots 128, records/receipts 1024, events 8192; smaller configured limits can reject earlier. Identifiers are 1–64 bytes from `[A-Za-z0-9._-]`.
- Every admitted token must eventually be executed and joined, including application-cancelled tokens. Dropping it does not free its evidence or reservation.
- One execute task and at most one observer of each registration/resumption acknowledgement per token. Observer waits are not cancellation-aware; the owner must drive or cancel the operation.
- Determinism covers only the explicitly acknowledged scenarios. No FIFO, scheduling, fairness, latency, general memory-use or liveness guarantee is made.
- Cleanup is cooperative in Swift. An external CI/container timeout means **incomplete**, never success. The subprocess launcher has bounded output/timeout/cleanup protocols but cannot guarantee termination of an unkillable kernel task or an escaping tool.
- No persistence, crash recovery, distributed actors, arbitrary executable loading, benchmark, UI, standards-compliance claim or cross-platform qualification.

Original application code is MIT © 2026 Lofrano Tecnologia. Swift/toolchain/runtime licenses are separate; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). For general contact use the [official homepage](https://lofranotecnologia.com.br); security reports use the repository's private reporting page in [SECURITY.md](SECURITY.md).
