#!/usr/bin/env python3
"""Exercise terminal ownership for nix-with-gh-token."""

from __future__ import annotations

import fcntl
import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


def spawn(
    runner: str,
    fake_gh_dir: str,
    command: str,
    *,
    log_file: str | None = None,
    tostop: bool = False,
) -> tuple[subprocess.Popen[bytes], int]:
    master, slave = pty.openpty()
    if tostop:
        attributes = termios.tcgetattr(slave)
        attributes[3] |= termios.TOSTOP
        termios.tcsetattr(slave, termios.TCSANOW, attributes)

    def make_controlling_terminal() -> None:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    environment = os.environ.copy()
    environment["PATH"] = f"{fake_gh_dir}:{environment['PATH']}"
    arguments = [runner]
    if log_file is not None:
        arguments.extend(["--log-file", log_file])
    arguments.extend(["--", "sh", "-c", command])
    process = subprocess.Popen(
        arguments,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
        preexec_fn=make_controlling_terminal,  # noqa: PLW1509 - isolated test child
    )
    os.close(slave)
    return process, master


def read_until(master: int, marker: bytes, timeout: float = 5.0) -> bytes:
    output = bytearray()
    deadline = time.monotonic() + timeout
    while marker not in output and time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.1)
        if readable:
            output.extend(os.read(master, 4096))
    if marker not in output:
        raise AssertionError(
            f"PTY output did not contain {marker!r}: {bytes(output)!r}"
        )
    return bytes(output)


def main() -> int:
    if len(sys.argv) not in {3, 4}:
        print(
            "Usage: test-foreground-pty.py RUNNER FAKE_GH_DIR [--nested-only]",
            file=sys.stderr,
        )
        return 64
    runner, fake_gh_dir = sys.argv[1:3]

    if len(sys.argv) == 4:
        if sys.argv[3] != "--nested-only":
            return 64
        with tempfile.TemporaryDirectory() as directory:
            log_file = str(Path(directory) / "nested-interrupt.jsonl")
            process, master = spawn(
                runner,
                fake_gh_dir,
                "nix nested-interrupt",
                log_file=log_file,
            )
            output = read_until(master, b"nested-interrupt-ready")
            os.write(master, b"\x03")
            deadline = time.monotonic() + 5
            nested_stopped = False
            while time.monotonic() < deadline:
                if Path(log_file).exists():
                    for line in Path(log_file).read_text(encoding="utf-8").splitlines():
                        try:
                            record = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if '"invocation-stop","status":130' in record.get("line", ""):
                            nested_stopped = True
                            break
                if nested_stopped:
                    break
                time.sleep(0.05)
            if not nested_stopped:
                raise AssertionError(
                    f"logged nested Ctrl-C was not forwarded: {output!r}"
                )
            os.close(master)
            status = process.wait(timeout=15)
            if status not in {129, 130}:
                raise AssertionError(
                    f"logged nested Ctrl-C exited {status}: {output!r}"
                )
        return 0

    process, master = spawn(
        runner, fake_gh_dir, 'read value; printf "received:%s\\n" "$value"'
    )
    os.write(master, b"pty-input\n")
    output = read_until(master, b"received:pty-input")
    status = process.wait(timeout=5)
    os.close(master)
    if status != 0:
        raise AssertionError(f"PTY stdin command exited {status}: {output!r}")

    process, master = spawn(
        runner,
        fake_gh_dir,
        "python3 -c 'import signal,sys,time; "
        'signal.signal(signal.SIGINT, lambda *_: (print("interrupted", flush=True), sys.exit(130))); '
        'print("ready", flush=True); time.sleep(30)\'',
    )
    output = read_until(master, b"ready")
    os.write(master, b"\x03")
    output += read_until(master, b"interrupted")
    status = process.wait(timeout=5)
    os.close(master)
    if status != 130:
        raise AssertionError(f"PTY Ctrl-C command exited {status}: {output!r}")

    process, master = spawn(
        runner,
        fake_gh_dir,
        "exec python3 -c 'import signal,time; "
        'signal.signal(signal.SIGCONT, lambda *_: print("resumed", flush=True)); '
        'print("suspend-ready", flush=True); time.sleep(30)\'',
    )
    output = read_until(master, b"suspend-ready")
    os.write(master, b"\x1a")
    time.sleep(0.2)
    os.killpg(process.pid, signal.SIGCONT)
    output += read_until(master, b"resumed")
    resumed_foreground = os.tcgetpgrp(master)
    if resumed_foreground == process.pid:
        raise AssertionError(
            "terminal ownership was not returned to the resumed command"
        )
    os.killpg(resumed_foreground, signal.SIGTERM)
    status = process.wait(timeout=5)
    os.close(master)
    if status != 143:
        raise AssertionError(f"PTY suspend/resume command exited {status}: {output!r}")

    with tempfile.TemporaryDirectory() as directory:
        log_file = str(Path(directory) / "tostop.jsonl")
        process, master = spawn(
            runner,
            fake_gh_dir,
            'printf "logger-visible\\n" >&2',
            log_file=log_file,
            tostop=True,
        )
        output = read_until(master, b"logger-visible")
        status = process.wait(timeout=5)
        os.close(master)
        if status != 0:
            raise AssertionError(f"TOSTOP logging command exited {status}: {output!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
