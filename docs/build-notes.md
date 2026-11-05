# Environment qualification and gates

## Selected identities

The supplied native environment qualification selected:

- Official image `swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855`.
- Swift 6.2.4, `swift-6.2.4-RELEASE`, Linux x86_64; tools version 6.2 and language mode 6.
- Real actor reentrancy, `Task.cancel`, `withTaskCancellationHandler`, checked continuations, `Synchronization.Mutex`, complete strict concurrency and warnings-as-errors were compiled/executed in native probes.
- Nonroot/offline SwiftPM `swift test --disable-sandbox --jobs 2`, bundled Swift Testing, outside-checkout source extraction and a separate local-package consumer were exercised by those environment probes.
- Swift source license retrieval identity is recorded in `environment.json`; it is not a hash of the image or compiler binary.

Environment/API probes do not establish that this implementation passes its own gates. Test, installed CLI and independent-consumer results must come from executing this package. Repeat the package gates when qualifying a different environment.

## Concrete resource and input decisions

Before implementation the numeric bounds were selected as capacity 1–64; live operations and barrier slots 1–128; retained operation records and receipts 1–1024; journal events 1–8192; identifiers 1–64 ASCII bytes; CLI argument bytes at most 256 KiB. This implementation reserves ten journal positions per admission. Exhaustion is a rejection, not evidence eviction. Smaller configurations remain valid even if too small to admit anything.

The runtime CLI has eight fixed scenarios, no arbitrary input workload, no subprocesses and no external packages. Scenario task-handle storage is capped at sixteen. Python tooling owns at most one direct compiler/CLI child at a time; tool output is at most 1 MiB, observation normally 180 seconds or 240 for builds/tests, cleanup observation five seconds. Package manifest at most 64 regular files, 16 KiB; source files at most 256 KiB; total uncompressed archive data at most 64 MiB. These are validation/observation bounds, not measured performance claims.

Writable caches are required:

```text
HOME=/tmp
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/swift-module-cache
CLANG_MODULE_CACHE_PATH=/tmp/clang-module-cache
```

The Dockerfile explicitly changes ownership of existing working directories before switching to UID/GID 1000. Source is mounted read-only. Scratch builds, installed artifacts and consumers use fresh owned `/tmp` directories outside the checkout.

## Shared gate retention

1. **Preparation:** only obtain actual official upstream artifacts. The immutable image identity above is consumed by the Dockerfile and checked against `environment.json`. Do not fabricate dependency locks, compiler hashes, OS package versions or a Package.resolved for this dependency-free package. Any additional redistributed artifact needs real identity, license and offline qualification before use.
2. **Isolation/resources:** every test/demo/package gate uses UID/GID 1000, network none, cap-drop ALL, no-new-privileges, 1 GiB memory, 2 CPUs and pids 256. Python checks effective capability, no-new-privileges, UID/GID and cgroup-v2 limits. Network isolation is enforced externally, not inferred from those checks. `/tmp` is an owned 512 MiB tmpfs within the memory limit, not extra memory. Passing counters does not prove general RSS or sandbox properties.
3. **Ownership:** fixed compiler and CLI tools run in acknowledged owned sessions, with bounded output and cleanup. No PID discovery or signalling after reaping. Outer Docker/CI operations belong to the trusted harness; neither Docker nor control sockets are mounted into the gate.
4. **CI:** one GitHub-hosted Ubuntu 24.04 job prepares the pinned official Swift image and installs Python from the official Ubuntu distribution. Separate test and package/demo steps consume that prepared image with `--pull=never` and network-none containers. The job does not require a configured self-hosted runner or share a local image cache across jobs. No host home, credentials, agent sockets or Docker socket enter the gate containers.
5. **Distribution:** explicit manifests, regular-file checks, source-byte verification, outside-checkout builds, installed EN/PT-BR CLI assertions and separate local SwiftPM consumer are mandatory. The full test gate runs against extracted source, not just the checkout. The installed CLI commands documented by both READMEs are executed from an empty working directory; their complete expected outputs are checked independently.
6. **Release quality:** original code is MIT. Source-only and dynamically linked CLI archives do not redistribute the compiler/runtime or OS libraries. Bundling them later would require exact license texts, runtime exceptions, source/artifact provenance and a complete redistributed-component inventory, not merely the notice links currently sufficient for these source/CLI-only artifacts.

Python 3 is a build-tool requirement, not a shipped dependency. The Dockerfile explicitly installs it during preparation because the pinned Swift base does not include it. Native runtime preparation must record its actual version; no package version is guessed. Shell entrypoints only replace themselves with the Python gate; runtime application code never invokes them.

The CI external step deadlines and 20-minute job bound are incomplete-observation limits. They neither prove Swift task termination nor claim fairness. A failure, resource kill, attempted unavailable resolution, lock drift, wrong compiler or incomplete cleanup blocks acceptance. Publication and deployment are not automated by this repository.
