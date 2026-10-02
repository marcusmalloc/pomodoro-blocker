#!/usr/bin/env python3
"""Exercise the domain helper against disposable files, as an ordinary user.

Usage: python3 scripts/test-domain-helper.py [path/to/PomodoroDomainHelper]
The default executable is .build/debug/PomodoroDomainHelper. The test never installs
a service, edits the system hosts file, or refreshes the system DNS cache.
"""

import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


class BSDInfo(ctypes.Structure):
    """Darwin's proc_bsdinfo from sys/proc_info.h, including the PID creation time."""

    _fields_ = [(name, ctypes.c_uint32) for name in [
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
        "svuid", "svgid", "reserved",
    ]] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in ["nfiles", "pgid", "pjobc", "tdev", "tpgid", "nice"]
    ] + [("seconds", ctypes.c_uint64), ("microseconds", ctypes.c_uint64)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".build/debug/PomodoroDomainHelper")
    arguments = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("Run this test as an ordinary user, without sudo.")
    executable = arguments.executable.resolve()
    if not executable.is_file() or not os.access(executable, os.X_OK):
        parser.error(f"Build the helper first; no executable found at {executable}")

    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int]
    libproc.proc_pidinfo.restype = ctypes.c_int

    def identity(pid):
        info = BSDInfo()
        size = ctypes.sizeof(info)
        if libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
            raise AssertionError(f"Couldn't inspect test process {pid}")
        return {"pid": pid, "uid": info.uid, "startedSeconds": info.seconds,
                "startedMicroseconds": info.microseconds}

    work = Path(tempfile.mkdtemp(prefix="pomodoro-helper-test-"))
    directory = work / "state"
    directory.mkdir(mode=0o755)
    os.chmod(directory, 0o755)
    hosts = work / "hosts"
    base = "127.0.0.1 localhost\n# unrelated user entry\n192.0.2.5 existing.example\n"
    hosts.write_text(base)
    os.chmod(hosts, 0o640)
    original = hosts.stat()
    request_path = directory / "request.json"
    status_path = directory / "status.json"
    helpers = []
    clients = []
    checks = []

    def start_helper():
        process = subprocess.Popen([str(executable), "--test", str(os.getuid()), str(hosts), str(directory)],
                                   stderr=subprocess.PIPE)
        helpers.append(process)
        return process

    helper = start_helper()

    def await_value(test, message, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if helper.poll() is not None:
                raise AssertionError(f"Helper exited during {message}: {helper.stderr.read().decode()}")
            if test():
                return
            time.sleep(0.05)
        raise AssertionError(message)

    def passed(message):
        checks.append(message)
        print(f"PASS {message}", flush=True)

    def status():
        try:
            return json.loads(status_path.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def write_bytes(data):
        with request_path.open("r+b", buffering=0) as output:
            fcntl.flock(output.fileno(), fcntl.LOCK_EX)
            try:
                output.truncate(0)
                output.write(data)
            finally:
                fcntl.flock(output.fileno(), fcntl.LOCK_UN)

    def request(names, lifetime=10, process=None):
        data = {"version": 1, "id": str(uuid.uuid4()), "process": process or identity(os.getpid()),
                "hostNames": names, "expiresAt": time.time() + lifetime}
        write_bytes(json.dumps(data).encode())
        return data

    def applied(data):
        return status().get("requestID") == data["id"] and not status().get("problem")

    def inactive():
        return hosts.read_text() == base

    try:
        await_value(lambda: status().get("version") == 1, "initial ready response")
        assert (request_path.stat().st_mode & 0o777) == 0o600
        assert (status_path.stat().st_mode & 0o777) == 0o644
        data = request(["example.com", "www.example.com"])
        await_value(lambda: applied(data) and "0.0.0.0 example.com" in hosts.read_text(), "active domains applied")
        passed("activate and receive a matching daemon acknowledgment")
        current = hosts.stat()
        assert (current.st_mode & 0o777) == 0o640
        assert current.st_uid == original.st_uid and current.st_gid == original.st_gid
        assert hosts.read_text().startswith(base)
        passed("preserve unrelated hosts entries, ownership and permissions")

        data = request(["changed.example"])
        await_value(lambda: applied(data) and "changed.example" in hosts.read_text()
                    and "0.0.0.0 example.com" not in hosts.read_text(), "changed list applied")
        passed("update the domain list")
        hosts.write_text(base)
        await_value(lambda: "changed.example" in hosts.read_text(), "externally removed marker restored")
        passed("repair an externally removed marker")
        before = status_path.stat().st_mtime_ns
        await_value(lambda: status_path.stat().st_mtime_ns > before, "fresh acknowledgment timestamp")
        passed("refresh an unchanged acknowledgment's timestamp")

        data = request([])
        await_value(lambda: applied(data) and inactive(), "inactive request cleanup")
        passed("remove blocks for an inactive request")
        data = request(["expiry.example"], lifetime=1)
        await_value(lambda: applied(data) and "expiry.example" in hosts.read_text(), "short lease applied")
        await_value(inactive, "lease expiry cleanup")
        passed("remove blocks after lease expiry")

        bad_process = identity(os.getpid())
        bad_process["startedMicroseconds"] = (bad_process["startedMicroseconds"] + 1) % 1_000_000
        data = request(["reuse.example"], process=bad_process)
        await_value(lambda: status().get("requestID") == data["id"] and bool(status().get("problem")),
                    "PID start mismatch rejected")
        assert inactive()
        passed("reject a reused PID with a mismatched process creation time")

        data = request(["malformed.example"])
        await_value(lambda: applied(data), "active before malformed request")
        write_bytes(b"{bad json")
        await_value(lambda: inactive() and bool(status().get("problem")), "malformed request cleanup")
        passed("clear blocks after a malformed request")

        data = request(["oversized.example"])
        await_value(lambda: applied(data), "active before oversized request")
        write_bytes(b" " * (1_048_576 + 1))
        await_value(lambda: inactive() and bool(status().get("problem")), "oversized request cleanup")
        passed("reject an oversized request and clear its previous block")

        data = request(["permissions.example"])
        await_value(lambda: applied(data), "active before permission mismatch")
        os.chmod(request_path, 0o644)
        await_value(lambda: inactive() and bool(status().get("problem")), "unsafe request permissions cleanup")
        os.chmod(request_path, 0o600)
        passed("reject unsafe request file permissions")

        data = request(["hardlink.example"])
        await_value(lambda: applied(data), "active before hard-linked request")
        link = work / "request-hardlink"
        os.link(request_path, link)
        await_value(lambda: inactive() and bool(status().get("problem")), "hard-linked request rejected")
        link.unlink()
        passed("reject a request file with multiple hard links")

        victim = work / "victim"
        victim.write_text("must stay unchanged")
        request_path.unlink()
        request_path.symlink_to(victim)
        await_value(lambda: bool(status().get("problem")) and "open" in status()["problem"],
                    "request symlink rejected")
        assert victim.read_text() == "must stay unchanged" and inactive()
        request_path.unlink()
        passed("reject a request symlink without touching its target")

        os.mkfifo(request_path, 0o600)
        await_value(lambda: bool(status().get("problem")) and "ownership" in status()["problem"],
                    "nonregular request rejected without hanging")
        request_path.unlink()
        request_path.write_text("")
        os.chmod(request_path, 0o600)
        passed("reject a FIFO without hanging the daemon")

        surviving_pid = helper.pid
        first_client = subprocess.Popen(["/bin/sleep", "20"])
        clients.append(first_client)
        data = request(["first-launch.example"], process=identity(first_client.pid))
        await_value(lambda: applied(data), "first app process request applied")
        first_client.terminate()
        first_client.wait(timeout=5)
        await_value(inactive, "first app process death cleanup")
        passed("clear blocks after the requesting app process exits")

        second_client = subprocess.Popen(["/bin/sleep", "20"])
        clients.append(second_client)
        data = request(["second-launch.example"], process=identity(second_client.pid))
        await_value(lambda: applied(data) and "second-launch.example" in hosts.read_text(),
                    "second app process request applied by existing helper")
        assert helper.pid == surviving_pid and helper.poll() is None
        second_client.terminate()
        second_client.wait(timeout=5)
        await_value(inactive, "second app process death cleanup")
        passed("reuse the same helper across two requesting app processes")

        data = request(["termination.example"])
        await_value(lambda: applied(data), "active before helper termination")
        helper.terminate()
        helper.wait(timeout=5)
        assert inactive() and helper.returncode == 0
        passed("remove active blocks when the helper receives TERM")

        hosts.write_text(base + f"# BEGIN PomodoroBlocker uid={os.getuid()}\n"
                         f"0.0.0.0 stale.example\n# END PomodoroBlocker uid={os.getuid()}\n")
        write_bytes(b"")
        helper = start_helper()
        await_value(inactive, "startup stale block cleanup")
        passed("remove stale blocks when the daemon restarts")
        print(f"{len(checks)} helper integration checks passed.", flush=True)
    finally:
        for client in clients:
            if client.poll() is None:
                client.terminate()
                client.wait(timeout=5)
        for process in helpers:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            errors = process.stderr.read().decode()
            if errors:
                print(errors)
            process.stderr.close()
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
