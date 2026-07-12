#!/usr/bin/env python3
"""Finite, non-interactive serial capture for agent-driven ESP-IDF verification.

Unlike esp-idf-monitor, this tool intentionally does not require a TTY. It only
captures serial output, optionally performs a hard reset, and can stop when a
regular expression is observed. Rich address decoding remains the job of the
official interactive monitor when a human terminal is available.
"""

from __future__ import annotations

import argparse
import errno
import json
import math
import multiprocessing
import re
import signal
import sys
import time
from pathlib import Path
from typing import Optional

try:
    import serial
except ImportError:  # pragma: no cover - exercised through shell error path
    serial = None


MAX_EXPECT_PATTERN_CHARS = 4096
MATCH_WINDOW_CHARS = 65_536
ROM_PATTERNS = (
    ("download_boot", re.compile(r"DOWNLOAD_BOOT\s*\(", re.IGNORECASE)),
    ("download_usb_uart", re.compile(r"DOWNLOAD\s*\((?:USB|UART0|USB/UART0)", re.IGNORECASE)),
    ("waiting_for_download", re.compile(r"(?<![A-Za-z])waiting for download(?![A-Za-z])", re.IGNORECASE)),
)


def nested_repeat(pattern: str) -> bool:
    """Conservatively detect a repeated group that already contains a repeat.

    Python's backtracking regex engine can take exponential time for constructs
    such as ``(a+)+$``. This small scanner deliberately handles only the
    unambiguous high-risk case; all remaining patterns are still isolated in a
    killable process below.
    """
    groups = []
    last_atom_repeat = False
    escaped = False
    in_class = False
    previous_was_quantifier = False
    index = 0

    while index < len(pattern):
        char = pattern[index]
        if escaped:
            escaped = False
            last_atom_repeat = False
            previous_was_quantifier = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if in_class:
            if char == "]":
                in_class = False
                last_atom_repeat = False
                previous_was_quantifier = False
            index += 1
            continue
        if char == "[":
            in_class = True
            index += 1
            continue
        if char == "(":
            groups.append(False)
            last_atom_repeat = False
            previous_was_quantifier = False
            index += 1
            continue
        if char == ")" and groups:
            last_atom_repeat = groups.pop()
            if groups and last_atom_repeat:
                groups[-1] = True
            previous_was_quantifier = False
            index += 1
            continue

        quantifier = False
        quantifier_end = index + 1
        if char in "*+?":
            # The ?/+ immediately following another quantifier is its lazy or
            # possessive modifier, not a second repetition. The question mark
            # in a ``(?...`` group extension is not a repetition either.
            group_extension = char == "?" and index > 0 and pattern[index - 1] == "("
            quantifier = not previous_was_quantifier and not group_extension
        elif char == "{" and not previous_was_quantifier:
            match = re.match(r"\{\d+(?:,\d*)?\}", pattern[index:])
            if match:
                quantifier = True
                quantifier_end = index + len(match.group(0))

        if quantifier:
            if last_atom_repeat:
                return True
            if groups:
                groups[-1] = True
            previous_was_quantifier = True
            index = quantifier_end
            continue

        # ``(?...`` introduces a group extension; its question mark is not a
        # quantifier. Other punctuation cannot be the atom repeated next.
        if char == "?" and index > 0 and pattern[index - 1] == "(":
            previous_was_quantifier = False
        else:
            last_atom_repeat = False
            previous_was_quantifier = False
        index += 1

    return False


def regex_worker(pattern: str, connection) -> None:
    """Run untrusted backtracking in a process the parent can terminate."""
    try:
        expected = re.compile(pattern)
        while True:
            text = connection.recv()
            if text is None:
                return
            connection.send(expected.search(text) is not None)
    except (EOFError, BrokenPipeError):
        return
    finally:
        connection.close()


class BoundedRegexMatcher:
    """Persistent regex worker bounded by the capture's monotonic deadline."""

    def __init__(self, pattern: str) -> None:
        context = multiprocessing.get_context("spawn")
        self._connection, child_connection = context.Pipe()
        self._process = context.Process(
            target=regex_worker, args=(pattern, child_connection), daemon=True
        )
        self._waiting = False
        self._process.start()
        child_connection.close()

    def search(self, text: str, deadline: float) -> Optional[bool]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            self._connection.send(text)
            self._waiting = True
            if not self._connection.poll(max(0.0, deadline - time.monotonic())):
                return None
            result = bool(self._connection.recv())
            self._waiting = False
            return result
        except (BrokenPipeError, EOFError, OSError):
            return None

    def close(self) -> None:
        try:
            # A worker still evaluating an unsafe expression cannot consume a
            # graceful-stop message, so terminate it directly rather than
            # enqueueing work that might leave shutdown waiting on the pipe.
            if self._process.is_alive() and not self._waiting:
                try:
                    self._connection.send(None)
                except (BrokenPipeError, EOFError, OSError):
                    pass
                self._process.join(0.05)
            if self._process.is_alive():
                self._process.terminate()
                self._process.join(0.1)
            if self._process.is_alive():
                self._process.kill()
                self._process.join(0.1)
        finally:
            self._connection.close()
            if not self._process.is_alive():
                self._process.close()


def project_baud(project: Optional[str]) -> Optional[int]:
    if not project:
        return None
    description = Path(project) / "build" / "project_description.json"
    try:
        value = json.loads(description.read_text(encoding="utf-8")).get("monitor_baud")
    except OSError:
        return None
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid project metadata JSON: {description}: {exc}") from exc
    if value in (None, ""):
        return None
    try:
        baud = int(value)
    except (ValueError, TypeError) as exc:
        raise ValueError(f"invalid monitor_baud in {description}: {value!r}") from exc
    if baud <= 0:
        raise ValueError(f"monitor_baud must be greater than zero in {description}: {baud}")
    return baud


def hard_reset(port: serial.SerialBase) -> None:
    """Match the official monitor's basic EN/RTS hard-reset sequence."""
    # ESP USB-UART auto-reset circuits invert these pyserial levels:
    # True is electrical LOW (assert EN reset), False is HIGH (release EN).
    port.setRTS(True)
    try:
        time.sleep(0.1)
    finally:
        # Even KeyboardInterrupt or an unexpected sleep failure must not leave
        # the target held in reset.
        port.setRTS(False)


def set_idle_control_lines(port: serial.SerialBase) -> bool:
    """Release EN/BOOT independently; return whether both controls exist."""
    unsupported = False
    failure = None
    for setter in (port.setRTS, port.setDTR):
        try:
            setter(False)
        except (OSError, serial.SerialException) as exc:
            if modem_control_is_unsupported(exc):
                unsupported = True
            elif failure is None:
                failure = exc
    if failure is not None:
        raise failure
    return not unsupported


def modem_control_is_unsupported(exc: BaseException) -> bool:
    """Only downgrade OS errors that prove modem control is unsupported."""
    return isinstance(exc, OSError) and exc.errno in {
        errno.ENOTTY,
        errno.ENOSYS,
        getattr(errno, "EOPNOTSUPP", errno.ENOTTY),
    }


def cleanup_port(port) -> bool:
    """Release both lines independently and close; report confirmed cleanup."""
    cleanup_ok = True
    for setter in (port.setRTS, port.setDTR):
        try:
            setter(False)
        except BaseException as exc:
            if not modem_control_is_unsupported(exc):
                cleanup_ok = False
    try:
        port.close()
    except BaseException:
        cleanup_ok = False
    return cleanup_ok


def rom_signature(text: str) -> Optional[str]:
    for name, pattern in ROM_PATTERNS:
        if pattern.search(text):
            return name
    return None


def open_serial_port(port_name: str, baud: int):
    """Open without pyserial's transient default levels resetting the board."""
    port = serial.serial_for_url(
        port_name, baudrate=baud, timeout=0.1, do_not_open=True
    )
    # Official esp-idf-monitor holds both lines LOW while opening, then returns
    # them to idle HIGH. In pyserial's inverted modem-control API that is
    # True/True before open and False/False after open.
    try:
        port.rts = True
        port.dtr = True
        port.open()
        try:
            controls_supported = set_idle_control_lines(port)
            if not controls_supported:
                print("WARN=serial port has no complete DTR/RTS control", file=sys.stderr)
        except (OSError, serial.SerialException) as exc:
            raise
    except BaseException:
        cleanup_port(port)
        raise
    return port


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--port", required=True, help="Serial port, e.g. /dev/cu.usbmodem101 or COM5")
    result.add_argument("--project", help="ESP-IDF project; used only to read build monitor_baud")
    result.add_argument("--baud", type=int, help="Baud rate; defaults to project metadata, then 115200")
    result.add_argument("--timeout", type=float, default=30.0, help="Maximum capture time in seconds")
    result.add_argument("--expect", help="Exit successfully as soon as this regular expression matches")
    result.add_argument("--reset", action="store_true", help="Hard-reset the target before capture")
    return result


def main() -> int:
    args = parser().parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        print("ERROR=timeout must be finite and greater than zero", file=sys.stderr)
        return 64
    if args.baud is not None and args.baud <= 0:
        print("ERROR=baud must be greater than zero", file=sys.stderr)
        return 64
    try:
        baud = args.baud if args.baud is not None else project_baud(args.project)
    except ValueError as exc:
        print(f"ERROR={exc}", file=sys.stderr)
        return 64
    baud = baud or 115200
    if args.expect and len(args.expect) > MAX_EXPECT_PATTERN_CHARS:
        print(
            f"ERROR=expect regex exceeds {MAX_EXPECT_PATTERN_CHARS} characters",
            file=sys.stderr,
        )
        return 64
    if args.expect and nested_repeat(args.expect):
        print("ERROR=unsafe expect regex: nested repetition is not allowed", file=sys.stderr)
        return 64
    try:
        expected = re.compile(args.expect) if args.expect else None
    except (re.error, RecursionError, OverflowError) as exc:
        print(f"ERROR=invalid expect regex: {exc}", file=sys.stderr)
        return 64

    if serial is None:
        print("DEPENDENCY_MISSING=pyserial", file=sys.stderr)
        print("ERROR=pyserial is unavailable; run this script through scripts/idf-env.sh", file=sys.stderr)
        print("DATA_SEEN=no", file=sys.stderr)
        print("CAPTURE_BYTES=0", file=sys.stderr)
        return 4

    try:
        port = open_serial_port(args.port, baud)
    except (OSError, ValueError, serial.SerialException) as exc:
        print(f"ERROR=unable to open serial port {args.port}: {exc}", file=sys.stderr)
        print("DATA_SEEN=no", file=sys.stderr)
        print("CAPTURE_BYTES=0", file=sys.stderr)
        return 2

    print(f"MONITOR_PORT={args.port}", file=sys.stderr)
    print(f"MONITOR_BAUD={baud}", file=sys.stderr)
    matched = False
    capture_bytes = 0
    window = ""
    classification_window = ""
    detected_rom_signature = None
    terminal_rc = None
    deadline = time.monotonic() + args.timeout
    matcher = None
    try:
        if expected:
            matcher = BoundedRegexMatcher(args.expect)
        try:
            port.reset_input_buffer()
        except (AttributeError, OSError, serial.SerialException) as exc:
            if not modem_control_is_unsupported(exc) and not isinstance(exc, AttributeError):
                print(f"WARN=unable to clear serial input buffer: {exc}", file=sys.stderr)
        if args.reset:
            try:
                hard_reset(port)
                print("RESET=hard", file=sys.stderr)
            except (OSError, serial.SerialException) as exc:
                print(f"WARN=hard reset control-line operation failed: {exc}", file=sys.stderr)

        while time.monotonic() < deadline:
            try:
                chunk = port.read(max(1, port.in_waiting))
            except (OSError, serial.SerialException) as exc:
                print(f"ERROR=serial read failed: {exc}", file=sys.stderr)
                terminal_rc = 3
                break
            if not chunk:
                continue
            capture_bytes += len(chunk)
            text = chunk.decode("utf-8", errors="replace")
            sys.stdout.write(text)
            sys.stdout.flush()
            classification_window = (classification_window + text)[-MATCH_WINDOW_CHARS:]
            detected_rom_signature = rom_signature(classification_window)
            if detected_rom_signature:
                break
            if expected:
                window = (window + text)[-MATCH_WINDOW_CHARS:]
                result = matcher.search(window, deadline)
                if result:
                    matched = True
                    break
                if result is None:
                    break
    except KeyboardInterrupt:
        terminal_rc = 130
    finally:
        if matcher:
            matcher.close()
        cleanup_ok = cleanup_port(port)
        print(f"DATA_SEEN={'yes' if capture_bytes else 'no'}", file=sys.stderr)
        print(f"CAPTURE_BYTES={capture_bytes}", file=sys.stderr)
        print(f"SERIAL_CLEANUP={'ok' if cleanup_ok else 'failed'}", file=sys.stderr)

    if not cleanup_ok:
        print("ERROR=serial cleanup could not confirm idle control lines and close", file=sys.stderr)
        return 3
    if detected_rom_signature:
        print("ROM_DOWNLOAD_MODE=yes", file=sys.stderr)
        print(f"ROM_SIGNATURE={detected_rom_signature}", file=sys.stderr)
        if expected:
            print("EXPECT_MATCH=no", file=sys.stderr)
        return 10
    print(f"ROM_DOWNLOAD_MODE={'no' if capture_bytes else 'unknown'}", file=sys.stderr)
    print("ROM_SIGNATURE=none", file=sys.stderr)
    if terminal_rc is not None:
        if expected:
            print("EXPECT_MATCH=no", file=sys.stderr)
        return terminal_rc
    if expected:
        print(f"EXPECT_MATCH={'yes' if matched else 'no'}", file=sys.stderr)
        return 0 if matched else 1
    return 0


def request_termination(_signum, _frame) -> None:
    raise KeyboardInterrupt()


if __name__ == "__main__":
    # The outer hard-wall timeout sends TERM first. Convert it to a normal
    # control-flow interruption so the capture finally block releases EN/BOOT
    # and closes the port before the process-group grace period expires.
    signal.signal(signal.SIGTERM, request_termination)
    raise SystemExit(main())
