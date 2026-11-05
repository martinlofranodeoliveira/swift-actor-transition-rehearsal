#!/usr/bin/env python3
"""Offline package gate. Child ownership is retained until waitpid reaps it."""
import hashlib
import io
import json
import os
import re
from pathlib import Path
import selectors
import shutil
import signal
import sys
import tarfile
import tempfile
import time

IMAGE = "swift:6.2-noble@sha256:22edf4bb29f6d43ad77bfdb1757666992d63a50ab124c41176f8c8c44ab69855"
LICENSE_HASH = "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55"
OUTPUT_LIMIT = 1048576
ARCHIVE_LIMIT = 67108864
ROOT = Path(__file__).resolve().parent.parent
COMMON = ["--disable-sandbox", "--jobs", "2", "-Xswiftc", "-strict-concurrency=complete", "-Xswiftc", "-warnings-as-errors"]
NAMES = ["stale", "capacity", "pre-cancel-task", "suspended-cancel-task", "resumed-cancel-task", "application-cancel", "commit-then-cancel", "snapshot"]
OUTCOMES = [["stale"], ["committed", "cancelled"], ["cancelled"], ["cancelled"], ["cancelled"], ["cancelled"], ["committed"], ["committed"]]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def owned(command, cwd, seconds=180):
    """Only fixed compiler and packaged CLI commands are passed by this module.

    The direct child setsid() and acknowledges over a private pipe before exec.
    The parent alone reaps it. No numeric signal is sent after reaping. Tools
    must not daemonize or escape this session; this is not a general sandbox.
    """
    # Ignored SIGCHLD survives exec; this single-threaded gate is the sole reaper.
    signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    ack_r, ack_w = os.pipe()
    out_r, out_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(ack_r)
            os.close(out_r)
            os.setsid()
            os.write(ack_w, b"R")
            os.close(ack_w)
            os.dup2(out_w, 1)
            os.dup2(out_w, 2)
            os.close(out_w)
            os.chdir(cwd)
            os.execvpe(str(command[0]), [str(x) for x in command], dict(os.environ))
        except BaseException:
            os._exit(127)
    os.close(ack_w)
    os.close(out_w)
    selector = selectors.DefaultSelector()
    for fd in (ack_r, out_r):
        os.set_blocking(fd, False)
        selector.register(fd, selectors.EVENT_READ)
    data = bytearray()
    ack = bytearray()
    status = None
    failure = None
    deadline = time.monotonic() + seconds
    cleanup_deadline = None
    reaped_at = None
    try:
        while True:
            now = time.monotonic()
            if failure is None and now >= deadline:
                failure = "incomplete scenario: owned tool watchdog expired"
            if failure is not None and cleanup_deadline is None:
                cleanup_deadline = now + 5
                if status is None:
                    # The unreaped direct child cannot have its PID reused.
                    try:
                        if ack == b"R":
                            os.killpg(pid, signal.SIGKILL)
                        else:
                            os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            for key, _ in selector.select(0.05):
                fd = key.fd
                chunk = os.read(fd, 65536)
                if not chunk:
                    selector.unregister(fd)
                    os.close(fd)
                elif fd == ack_r:
                    ack.extend(chunk)
                    if ack != b"R":
                        failure = "incomplete tool session acknowledgement"
                else:
                    remaining = OUTPUT_LIMIT - len(data)
                    data.extend(chunk[:max(remaining, 0)])
                    if len(chunk) > remaining:
                        failure = "owned tool output limit exceeded"
            if status is None:
                found, result = os.waitpid(pid, os.WNOHANG)
                if found == pid:
                    status = result
                    reaped_at = time.monotonic()
                    # From here on, this function never signals pid or its group.
            if status is not None and not selector.get_map():
                break
            now = time.monotonic()
            if status is not None and reaped_at is not None and now - reaped_at > 5:
                failure = "incomplete cleanup: output pipe retained after direct child exit"
                break
            if cleanup_deadline is not None and now >= cleanup_deadline:
                failure = "incomplete cleanup: outer isolated harness must tear down the gate"
                break
    finally:
        for key in list(selector.get_map().values()):
            os.close(key.fd)
        selector.close()
    require(status is not None, failure or "incomplete cleanup")
    require(failure is None, failure)
    require(ack == b"R", "missing tool session acknowledgement")
    text = data.decode("utf-8", errors="replace")
    require(os.waitstatus_to_exitcode(status) == 0, "owned tool failed:\n" + text)
    return text


def environment():
    require(os.getuid() == 1000 and os.getgid() == 1000, "gate requires UID/GID 1000")
    status = Path("/proc/self/status").read_text()
    fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
    require(int(fields["CapEff"].strip(), 16) == 0, "gate requires cap-drop ALL")
    require(fields["NoNewPrivs"].strip() == "1", "gate requires no-new-privileges")
    cgroup = Path("/sys/fs/cgroup")
    for name, maximum in [("memory.max", 1073741824), ("pids.max", 256)]:
        value = (cgroup / name).read_text().strip()
        require(value != "max" and 0 < int(value) <= maximum, "invalid resource gate: " + name)
    quota, period = (cgroup / "cpu.max").read_text().split()
    require(quota != "max" and 0 < int(quota) <= 2 * int(period), "gate requires at most two CPUs")
    lock = json.loads((ROOT / "environment.json").read_text())
    require(lock["image"] == IMAGE and lock["swiftLicenseSHA256"] == LICENSE_HASH, "environment lock drift")
    require(IMAGE in (ROOT / "Dockerfile").read_text(), "Dockerfile image drift")
    os.environ["HOME"] = "/tmp"
    os.environ["SWIFTPM_MODULECACHE_OVERRIDE"] = "/tmp/swift-module-cache"
    os.environ["CLANG_MODULE_CACHE_PATH"] = "/tmp/clang-module-cache"
    for name in ("SWIFTPM_MODULECACHE_OVERRIDE", "CLANG_MODULE_CACHE_PATH"):
        Path(os.environ[name]).mkdir(exist_ok=True)
    swift = shutil.which("swift")
    require(swift is not None, "Swift is required")
    version = owned([swift, "--version"], ROOT)
    require("Swift version 6.2.4" in version and "x86_64-unknown-linux-gnu" in version, "unsupported toolchain identity")
    return swift


def manifest():
    text = (ROOT / "scripts/package-files.txt").read_text()
    require(len(text.encode()) <= 16384, "manifest too large")
    names = text.splitlines()
    require(1 <= len(names) <= 64 and len(set(names)) == len(names), "invalid manifest")
    for name in names:
        path = Path(name)
        require(not path.is_absolute() and all(p not in ("", ".", "..", ".git", ".build", "build", "dist", "target", "node_modules") for p in path.parts), "unsafe manifest path")
        source = ROOT / path
        require(source.is_file() and not source.is_symlink(), "manifest requires regular files")
        require(source.stat().st_size <= 262144, "source file exceeds package bound")
    for readme in ("README.md", "README.pt-BR.md"):
        doc = (ROOT / readme).read_text()
        for command in ("/bin/sh scripts/test-offline.sh", "/bin/sh scripts/demo-offline.sh --assert", "/bin/sh scripts/package.sh"):
            require(command in doc, "documented command missing: " + readme)
    return names


def archive(destination, files):
    total = sum(len(data) for _, data, _ in files)
    require(total <= ARCHIVE_LIMIT and len(files) <= 64, "package bound exceeded")
    with tarfile.open(destination, "w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data, mode in sorted(files):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = mode
            info.uid = info.gid = info.mtime = 0
            tar.addfile(info, io.BytesIO(data))


def extract_verified(archive_path, destination, expected):
    with tarfile.open(archive_path, "r:") as tar:
        members = tar.getmembers()
        require(sorted(m.name for m in members) == sorted(expected), "package content mismatch")
        require(len(members) <= 64 and sum(m.size for m in members) <= ARCHIVE_LIMIT, "archive bounds exceeded")
        for member in members:
            require(member.isfile() and member.name in expected, "nonregular archive member")
            parts = Path(member.name).parts
            require(not member.name.startswith("/") and ".." not in parts, "unsafe archive member")
            data = tar.extractfile(member).read(ARCHIVE_LIMIT + 1)
            require(hashlib.sha256(data).digest() == hashlib.sha256(expected[member.name]).digest(), "archive byte mismatch")
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(member.mode & 0o777)


def swift_command(swift, verb, scratch, extra=()):
    return [swift, verb, *COMMON, "--scratch-path", str(scratch), *extra]


def expected_human(language):
    development, passed, reservations = ("development", "PASS", "reservations") if language == "en" else ("desenvolvimento", "OK", "reservas")
    lines = ["Actor Transition Rehearsal 0.1.0 (" + development + ")"]
    lines += [f"{passed} {name}: {','.join(outcomes)}; {reservations}=0" for name, outcomes in zip(NAMES, OUTCOMES)]
    return "\n".join(lines) + "\n"


def demos(binary, cwd):
    require(owned([binary, "--version"], cwd) == "Actor Transition Rehearsal 0.1.0 (development)\n", "installed version mismatch")
    for language in ("en", "pt-BR"):
        text = owned([binary, "--assert", "--language", language], cwd)
        require(text == expected_human(language), "installed documented demo mismatch")
        print(text, end="")
    first = owned([binary, "--assert", "--json"], cwd)
    second = owned([binary, "--assert", "--json"], cwd)
    require(first == second, "acknowledged transcript is not repeatable")
    report = json.loads(first)
    require(report["version"] == "0.1.0", "report version mismatch")
    require([s["name"] for s in report["scenarios"]] == NAMES, "missing scenario")
    outcomes = [[o["receipt"]["outcome"] for o in s["snapshot"]["operations"]] for s in report["scenarios"]]
    require(outcomes == OUTCOMES, "receipt oracle mismatch")


def consumer(swift, workspace, source):
    directory = workspace / "consumer"
    directory.mkdir()
    dependency = os.path.relpath(source, directory)
    (directory / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "IndependentConsumer", dependencies: [.package(path: "''' + dependency + '''")], targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "ActorTransitionRehearsal", package: "actor-transition-rehearsal")])], swiftLanguageModes: [.v6])
''')
    sources = directory / "Sources/Consumer"
    sources.mkdir(parents=True)
    (sources / "Consumer.swift").write_text('''import ActorTransitionRehearsal
@main struct Consumer {
    static func main() async throws {
        let ledger = Rehearsal(limits: try Limits(capacity: 1))
        let token = try await ledger.admit("independent")
        let task = Task { try await ledger.execute(token) }
        do {
            let registration = try await token.registration()
            guard registration.disposition == .registered else { throw LabError.assertionFailed }
            _ = try await ledger.invalidate()
            let release = try await ledger.release(token, at: .suspension)
            guard release == .released else { throw LabError.assertionFailed }
            let receipt = try await task.value
            let snapshot = await ledger.snapshot()
            let waiters = await ledger.registeredWaiters()
            guard receipt.outcome == .stale, snapshot.committedCount == 0,
                  snapshot.reservedCapacity == 0, waiters == 0 else { throw LabError.assertionFailed }
            print("independent consumer: stale, reservations=0")
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
    }
}
''')
    output = owned(swift_command(swift, "run", workspace / "consumer-build", ["Consumer"]), directory)
    require("independent consumer: stale, reservations=0\n" in output, "independent consumer failed")


def gate(mode):
    swift = environment()
    names = manifest()
    # All package installation, compilation and CLI execution occurs outside ROOT.
    with tempfile.TemporaryDirectory(prefix="atr-gate-", dir="/tmp") as temporary:
        workspace = Path(temporary)
        source_tar = workspace / "actor-transition-rehearsal-source-0.1.0.tar"
        source_files = [("actor-transition-rehearsal/" + name, (ROOT / name).read_bytes(), 0o755 if name.endswith(".sh") else 0o644) for name in names]
        archive(source_tar, source_files)
        extracted = workspace / "source"
        extracted.mkdir()
        extract_verified(source_tar, extracted, {name: data for name, data, _ in source_files})
        source = extracted / "actor-transition-rehearsal"
        if mode == "test":
            test_output = owned(swift_command(swift, "test", workspace / "test-build"), source, seconds=240)
            matches = re.findall(r"Test run with ([0-9]+) tests? in [0-9]+ suites? passed", test_output)
            require(bool(matches) and int(matches[-1]) >= 8, "Swift Testing discovery did not confirm at least eight passing tests")
            print("Swift Testing: " + matches[-1] + " tests passed")
        release_scratch = workspace / "release-build"
        owned(swift_command(swift, "build", release_scratch, ["-c", "release", "--product", "actor-transition-rehearsal"]), source, seconds=240)
        bin_text = owned(swift_command(swift, "build", release_scratch, ["-c", "release", "--show-bin-path"]), source)
        bin_directory = Path(bin_text.strip()).resolve()
        require(bin_directory.is_relative_to(release_scratch), "unexpected binary directory")
        executable = bin_directory / "actor-transition-rehearsal"
        require(executable.is_file() and not executable.is_symlink(), "missing CLI")
        docs = ["LICENSE", "README.md", "README.pt-BR.md", "THIRD_PARTY_NOTICES.md", "environment.json", "docs/contract.md", "docs/design.md", "docs/build-notes.md", "licenses/Swift-6.2.4-LICENSE.txt"]
        cli_files = [("bin/actor-transition-rehearsal", executable.read_bytes(), 0o755)]
        cli_files += [(name, (source / name).read_bytes(), 0o644) for name in docs]
        cli_tar = workspace / "actor-transition-rehearsal-cli-0.1.0.tar"
        archive(cli_tar, cli_files)
        install = workspace / "installed"
        install.mkdir()
        extract_verified(cli_tar, install, {name: data for name, data, _ in cli_files})
        outside = workspace / "empty-working-directory"
        outside.mkdir()
        demos(install / "bin/actor-transition-rehearsal", outside)
        if mode == "test":
            consumer(swift, workspace, source)
        if mode == "package":
            output = Path("/tmp/atr-artifacts")
            output.mkdir(exist_ok=True)
            for path in (source_tar, cli_tar):
                target = output / path.name
                require(not target.is_symlink(), "refusing artifact symlink")
                shutil.copyfile(path, target)
                print(f"{target}: sha256={hashlib.sha256(target.read_bytes()).hexdigest()}")
        print("offline " + mode + " gate: PASS")


def main():
    args = sys.argv[1:]
    require(args in (["test"], ["demo"], ["demo", "--assert"], ["package"]), "usage: gate.py test|demo [--assert]|package")
    gate(args[0])


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("gate failure: " + str(error)[:OUTPUT_LIMIT], file=sys.stderr)
        sys.exit(1)
