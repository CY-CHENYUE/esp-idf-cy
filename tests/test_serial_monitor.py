#!/usr/bin/env python3
from __future__ import print_function

import json
import importlib.util
import os
import pty
import subprocess
import sys
import tempfile
import threading
import time


SCRIPT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "scripts", "serial_monitor.py")
)
WRAPPER = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "scripts", "monitor.sh")
)
TIMEOUT_HELPER = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "scripts", "process_timeout.py")
)


def test_control_line_polarity():
    spec = importlib.util.spec_from_file_location("esp_idf_cy_serial_monitor", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    class FakeSerialException(Exception):
        pass

    class FakePort(object):
        def __init__(self, fail_release=False, interrupt_open=False):
            self.events = []
            self._rts = None
            self._dtr = None
            self.fail_release = fail_release
            self.interrupt_open = interrupt_open
            self.closed = False

        @property
        def rts(self):
            return self._rts

        @rts.setter
        def rts(self, value):
            self._rts = value
            self.events.append(("rts=", value))

        @property
        def dtr(self):
            return self._dtr

        @dtr.setter
        def dtr(self, value):
            self._dtr = value
            self.events.append(("dtr=", value))

        def open(self):
            self.events.append(("open",))
            if self.interrupt_open:
                raise KeyboardInterrupt()

        def setRTS(self, value):
            self._rts = value
            self.events.append(("setRTS", value))
            if value is False and self.fail_release:
                raise OSError(5, "cannot release RTS")

        def setDTR(self, value):
            self._dtr = value
            self.events.append(("setDTR", value))

        def close(self):
            self.closed = True
            self.events.append(("close",))

    fake_port = FakePort()

    class FakeSerialApi(object):
        SerialException = FakeSerialException

        @staticmethod
        def serial_for_url(*args, **kwargs):
            assert kwargs["do_not_open"] is True
            return fake_port

    module.serial = FakeSerialApi()
    opened = module.open_serial_port("COM5", 115200)
    assert opened is fake_port
    assert fake_port.events == [
        ("rts=", True),
        ("dtr=", True),
        ("open",),
        ("setRTS", False),
        ("setDTR", False),
    ], fake_port.events
    assert fake_port._rts is False and fake_port._dtr is False

    fake_port.events = []
    original_sleep = module.time.sleep
    module.time.sleep = lambda _seconds: None
    module.hard_reset(fake_port)
    assert fake_port.events == [("setRTS", True), ("setRTS", False)]
    assert fake_port._rts is False

    def interrupted_sleep(_seconds):
        raise KeyboardInterrupt()

    fake_port.events = []
    module.time.sleep = interrupted_sleep
    try:
        module.hard_reset(fake_port)
    except KeyboardInterrupt:
        pass
    else:
        raise AssertionError("hard_reset should propagate KeyboardInterrupt")
    assert fake_port.events == [("setRTS", True), ("setRTS", False)]
    assert fake_port._rts is False
    module.time.sleep = original_sleep

    # A real release failure is fatal: best-effort both lines, close, rethrow.
    failing_port = FakePort(fail_release=True)
    FakeSerialApi.serial_for_url = staticmethod(lambda *args, **kwargs: failing_port)
    try:
        module.open_serial_port("COM6", 115200)
    except OSError:
        pass
    else:
        raise AssertionError("RTS release failure must fail open")
    assert failing_port.closed is True
    assert ("setDTR", False) in failing_port.events

    # An interrupt during a partially completed open also closes and attempts
    # to leave both control lines idle before propagating the interrupt.
    interrupted_port = FakePort(interrupt_open=True)
    FakeSerialApi.serial_for_url = staticmethod(lambda *args, **kwargs: interrupted_port)
    try:
        module.open_serial_port("COM7", 115200)
    except KeyboardInterrupt:
        pass
    else:
        raise AssertionError("open interrupt must propagate")
    assert interrupted_port.closed is True
    assert ("setRTS", False) in interrupted_port.events
    assert ("setDTR", False) in interrupted_port.events


def run_capture(expect, payload, timeout="1.5", project=None):
    master, slave = pty.openpty()
    command = [
        sys.executable,
        SCRIPT,
        "--port",
        os.ttyname(slave),
        "--timeout",
        timeout,
        "--expect",
        expect,
    ]
    if project:
        command.extend(["--project", project])
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.15)
    if payload:
        os.write(master, payload)
    stdout, stderr = process.communicate(timeout=4)
    os.close(master)
    os.close(slave)
    return process.returncode, stdout.decode("utf-8"), stderr.decode("utf-8")


def main():
    test_control_line_polarity()

    rc, stdout, stderr = run_capture("READY=1", b"booting\r\nREADY=1\r\n")
    assert rc == 0, (rc, stdout, stderr)
    assert "READY=1" in stdout
    assert "EXPECT_MATCH=yes" in stderr

    rc, stdout, stderr = run_capture("(?:READY|DONE)+", b"READYDONE\r\n")
    assert rc == 0, (rc, stdout, stderr)
    assert "EXPECT_MATCH=yes" in stderr

    rc, stdout, stderr = run_capture("NEVER", b"booting only\r\n", timeout="0.3")
    assert rc == 1, (rc, stdout, stderr)
    assert "EXPECT_MATCH=no" in stderr
    assert "SERIAL_CLEANUP=ok" in stderr

    # The outer process-group deadline must allow serial_monitor's SIGTERM
    # handler/finally block to publish cleanup evidence before rc124 returns.
    master, slave = pty.openpty()
    process = subprocess.Popen(
        [
            sys.executable,
            TIMEOUT_HELPER,
            "1",
            "--",
            sys.executable,
            SCRIPT,
            "--port",
            os.ttyname(slave),
            "--timeout",
            "10",
            "--expect",
            "NEVER",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout, stderr_bytes = process.communicate(timeout=4)
    os.close(master)
    os.close(slave)
    stderr = stderr_bytes.decode("utf-8")
    assert process.returncode == 124, (process.returncode, stdout, stderr)
    assert "DATA_SEEN=no" in stderr
    assert "ROM_DOWNLOAD_MODE=unknown" in stderr
    assert "SERIAL_CLEANUP=ok" in stderr

    for expected_signature, payload in (
        ("download_boot", b"boot:0x5 (DOWNLOAD_BOOT(UART0/USB))\r\n"),
        ("download_usb_uart", b"mode: DOWNLOAD(USB/UART0)\r\n"),
        ("waiting_for_download", b"waiting for download\r\n"),
    ):
        rc, stdout, stderr = run_capture("DOWNLOAD", payload)
        assert rc == 10, (expected_signature, rc, stdout, stderr)
        assert "ROM_DOWNLOAD_MODE=yes" in stderr
        assert "ROM_SIGNATURE=" + expected_signature in stderr
        assert "EXPECT_MATCH=no" in stderr

    started = time.monotonic()
    rc, stdout, stderr = run_capture("(a+)+$", b"", timeout="0.3")
    elapsed = time.monotonic() - started
    assert rc == 64, (rc, stdout, stderr)
    assert "unsafe expect regex: nested repetition" in stderr
    assert elapsed < 1.0, elapsed

    # Ambiguous alternation is not rejected by the narrow static check. It is
    # nevertheless confined to a child process and cannot overrun the capture
    # deadline or leave a stuck matcher thread/process behind.
    started = time.monotonic()
    rc, stdout, stderr = run_capture("(a|aa)+Z", b"a" * 200, timeout="0.3")
    elapsed = time.monotonic() - started
    assert rc == 1, (rc, stdout, stderr)
    assert "EXPECT_MATCH=no" in stderr
    assert elapsed < 1.5, elapsed

    master, slave = pty.openpty()
    process = subprocess.Popen(
        ["bash", WRAPPER, "-p", os.ttyname(slave), "-t", "3", "-e", "WRAPPED=1"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    # IDF export time varies; keep writing in parallel until the wrapper has
    # opened the slave PTY instead of relying on a brittle fixed delay.
    def writer():
        for _ in range(40):
            if process.poll() is not None:
                break
            try:
                os.write(master, b"WRAPPED=1\r\n")
            except OSError:
                break
            time.sleep(0.2)

    thread = threading.Thread(target=writer)
    thread.start()
    stdout, stderr = process.communicate(timeout=6)
    thread.join(timeout=1)
    os.close(master)
    os.close(slave)
    assert process.returncode == 0, (process.returncode, stdout, stderr)
    assert b"WRAPPED=1" in stdout
    assert b"EXPECT_MATCH=yes" in stderr

    with tempfile.TemporaryDirectory() as project:
        build = os.path.join(project, "build")
        os.makedirs(build)
        with open(os.path.join(build, "project_description.json"), "w") as handle:
            json.dump({"monitor_baud": "9600"}, handle)
        rc, stdout, stderr = run_capture("OK", b"OK\n", project=project)
        assert rc == 0, (rc, stdout, stderr)
        assert "MONITOR_BAUD=9600" in stderr

    print("PASS=test_serial_monitor")


if __name__ == "__main__":
    main()
