#!/usr/bin/env python3
"""Run one argv command in its own process group with a hard wall timeout."""

from __future__ import annotations

import argparse
import ctypes
import math
import os
import signal
import subprocess
import sys
import time


class WindowsIOCounters(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_ulonglong),
        ("WriteOperationCount", ctypes.c_ulonglong),
        ("OtherOperationCount", ctypes.c_ulonglong),
        ("ReadTransferCount", ctypes.c_ulonglong),
        ("WriteTransferCount", ctypes.c_ulonglong),
        ("OtherTransferCount", ctypes.c_ulonglong),
    ]


class WindowsBasicLimits(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", ctypes.c_ulong),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", ctypes.c_ulong),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", ctypes.c_ulong),
        ("SchedulingClass", ctypes.c_ulong),
    ]


class WindowsExtendedLimits(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", WindowsBasicLimits),
        ("IoInfo", WindowsIOCounters),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class WindowsKillOnCloseJob:
    """Minimal Windows Job Object that owns and kills the full process tree."""

    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = 9

    def __init__(self) -> None:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateJobObjectW.restype = ctypes.c_void_p
        kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]
        kernel32.SetInformationJobObject.restype = ctypes.c_int
        kernel32.SetInformationJobObject.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_ulong,
        ]
        kernel32.AssignProcessToJobObject.restype = ctypes.c_int
        kernel32.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_int
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        self._kernel32 = kernel32
        self._handle = kernel32.CreateJobObjectW(None, None)
        if not self._handle:
            raise OSError(ctypes.get_last_error(), "CreateJobObjectW failed")
        limits = WindowsExtendedLimits()
        limits.BasicLimitInformation.LimitFlags = self.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        ok = kernel32.SetInformationJobObject(
            self._handle,
            self.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
            ctypes.byref(limits),
            ctypes.sizeof(limits),
        )
        if not ok:
            self.close()
            raise OSError(ctypes.get_last_error(), "SetInformationJobObject failed")

    def assign(self, process) -> None:
        process_handle = ctypes.c_void_p(int(process._handle))
        if not self._kernel32.AssignProcessToJobObject(self._handle, process_handle):
            raise OSError(ctypes.get_last_error(), "AssignProcessToJobObject failed")

    def close(self) -> None:
        if getattr(self, "_handle", None):
            self._kernel32.CloseHandle(self._handle)
            self._handle = None


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("timeout", type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command or not math.isfinite(args.timeout) or args.timeout <= 0:
        print("ERROR=process_timeout requires positive seconds and a command", file=sys.stderr)
        raise SystemExit(64)
    return args


def group_exists(group_id: int) -> bool:
    if os.name == "nt":
        # Windows tree lifetime is managed by taskkill below; the leader's
        # poll() remains the authoritative wait condition.
        return False
    try:
        os.killpg(group_id, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_group(group_id: int, grace: float = 0.6) -> None:
    if os.name == "nt":
        # /T includes descendants and /F supplies the hard-kill guarantee that
        # MSYS timeout alone cannot provide for native Windows processes.
        subprocess.run(
            ["taskkill.exe", "/PID", str(group_id), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return
    try:
        os.killpg(group_id, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline and group_exists(group_id):
        time.sleep(0.02)
    if group_exists(group_id):
        try:
            os.killpg(group_id, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def main() -> int:
    args = parse_args()
    interrupted = {"signal": None}
    process_holder = {"process": None}

    def relay(signum, _frame):
        interrupted["signal"] = signum
        active = process_holder["process"]
        if active is not None:
            stop_group(active.pid)

    old_term = signal.signal(signal.SIGTERM, relay)
    old_int = signal.signal(signal.SIGINT, relay)
    process = None
    windows_job = None
    try:
        try:
            if os.name == "nt":
                windows_job = WindowsKillOnCloseJob()
            spawn_options = (
                {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
                if os.name == "nt"
                else {"start_new_session": True}
            )
            process = subprocess.Popen(args.command, **spawn_options)
            process_holder["process"] = process
            if windows_job is not None:
                windows_job.assign(process)
        except OSError as exc:
            print(f"ERROR=unable to start bounded command: {exc}", file=sys.stderr)
            return 127
        if interrupted["signal"] is not None:
            stop_group(process.pid)
            return 128 + int(interrupted["signal"])
        try:
            return_code = process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            stop_group(process.pid)
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                pass
            return 124
        if interrupted["signal"] is not None:
            return 128 + int(interrupted["signal"])
        # A helper may exit while leaving a background descendant holding the
        # capture pipe or serial port. Bounded calls never permit survivors.
        if group_exists(process.pid):
            stop_group(process.pid)
        return 128 + abs(return_code) if return_code < 0 else return_code
    finally:
        if process is not None and (process.poll() is None or group_exists(process.pid)):
            stop_group(process.pid)
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                pass
        if windows_job is not None:
            # KILL_ON_JOB_CLOSE also removes descendants left behind after a
            # normally exiting Windows helper, preventing inherited pipes or
            # serial handles from surviving the wrapper.
            windows_job.close()
        signal.signal(signal.SIGTERM, old_term)
        signal.signal(signal.SIGINT, old_int)


if __name__ == "__main__":
    raise SystemExit(main())
