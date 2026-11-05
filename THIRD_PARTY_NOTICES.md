# License and provenance inventory

## Original application

Actor Transition Rehearsal development 0.1.0 is original application/library, test, script and documentation code by Lofrano Tecnologia, licensed under the included MIT LICENSE, copyright 2026. Organization metadata intentionally contains no email address.

## Exact selected toolchain/runtime — not MIT

| Item | Selected identity | Distribution relationship |
| --- | --- | --- |
| Official Swift Linux OCI environment | `swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855` | Build/run prerequisite; not included in either archive |
| Swift compiler, standard library, concurrency runtime, Synchronization and bundled Swift Testing | Swift 6.2.4, `swift-6.2.4-RELEASE`, Linux x86_64 | Toolchain/runtime prerequisite; no runtime library files copied into archives |
| Foundation APIs | Those supplied with the selected official Swift environment | Used for JSON and CLI I/O; not redistributed as library files |
| External Swift packages | None | No Package.resolved required or supplied |
| OS libraries and build tools, including Python 3 | Python 3 is explicitly installed from the official Ubuntu distribution during Docker preparation; other OS libraries come from the pinned Swift image | External environment, not redistributed by this project; no invented per-package version inventory |

Swift source/license provenance:

- Source release: https://github.com/swiftlang/swift/tree/swift-6.2.4-RELEASE
- Exact license text: https://raw.githubusercontent.com/swiftlang/swift/swift-6.2.4-RELEASE/LICENSE.txt
- Retrieved text SHA-256: `770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55`
- License: **Apache License 2.0 with Runtime Library Exception**. The applicable exception is part of that upstream license text. It must not be dropped or replaced with this application's MIT license.
- Official toolchain source/provenance: https://github.com/swiftlang/swift
- SwiftPM documentation: https://www.swift.org/documentation/package-manager/

The source package contains no copied upstream implementation. The retrieved complete Swift license and Runtime Library Exception are preserved in `licenses/Swift-6.2.4-LICENSE.txt`. The CLI archive contains the project's compiled executable and notices, not a copy of the compiler, standard library, Foundation shared libraries, concurrency shared library or OS image. The exact selected environment remains necessary to run it. The runtime-library exception is relevant to compiled Swift application distribution; this notice does not substitute for the actual upstream terms or assert that every toolchain/OS component has one license.

If a future distribution bundles a runtime, compiler, image or additional libraries, its release gate must retrieve and preserve the actual component license texts, exceptions, notices and source/artifact provenance for everything redistributed. No such bundled distribution is claimed here. This inventory is a provenance boundary, not legal advice or a certification of broad license compliance.
