# Contributing

Contributions should preserve the narrow development 0.1.0 contract. Use synthetic identifiers and fixtures only; do not include personal data, private client code, secrets, telemetry or copied proprietary material.

Use the exact environment and offline container command in README.md or README.pt-BR.md. Run:

```sh
/bin/sh scripts/test-offline.sh
/bin/sh scripts/demo-offline.sh --assert
/bin/sh scripts/package.sh
```

The full gate tests extracted sources, a separately installed CLI and a separate consumer. A checkout-only `swift test` pass is insufficient. Changes to acknowledgements need purposeful regression fixtures that could fail under an incorrect ordering, not assertions duplicating implementation calculations. Do not use sleeps as actor coordination. Keep each task retained and joined, single-resume continuations, checked counters and bookkeeping reserved before suspension.

When adding a source/document file, update `scripts/package-files.txt`. Keep both READMEs and the contract synchronized. Do not add external Swift packages or change the selected compiler without actual API, offline, resource, provenance and license qualification. Do not fabricate locks or qualification results. Unsafe SwiftPM product build flags should not be used to force consumer settings; the gate supplies strict compiler flags explicitly.

Pull requests should describe observable behavior, the relevant acceptance scenario, failure/cleanup semantics and commands actually run. Do not assert production readiness, benchmark improvements, broad standards conformance or general scheduler determinism.

Original contributions are accepted under the project's MIT license. General contact: https://lofranotecnologia.com.br . Security issues belong in the private channel in SECURITY.md, not public issues. There is no promised response-time SLA.
