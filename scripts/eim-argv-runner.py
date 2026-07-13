#!/usr/bin/env python3
"""Execute an argv vector produced by esp-idf-cy without a command shell.

EIM's ``run`` API accepts a shell command string.  esp-idf-cy therefore gives
EIM one fixed command which starts this file.  The actual command arguments
travel in a mode-0600, NUL-separated UTF-8 file and are never interpolated into
the EIM command string.
"""

from __future__ import annotations

import os
import shutil
import stat
import sys
from pathlib import Path


MAX_ARGV_BYTES = 4 * 1024 * 1024


def fail(message: str, code: int = 64) -> int:
    print(f"ERROR={message}", file=sys.stderr)
    return code


def read_argv(path: Path) -> list[str]:
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("argv payload is not a regular file")
        if os.name != "nt" and info.st_mode & 0o077:
            raise PermissionError("argv payload permissions must be 0600 or stricter")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            payload = stream.read(MAX_ARGV_BYTES + 1)
    finally:
        os.close(fd)

    if len(payload) > MAX_ARGV_BYTES:
        raise ValueError("argv payload exceeds 4 MiB")
    if not payload or payload[-1:] != b"\0":
        raise ValueError("argv payload is empty or missing its final NUL")

    raw_arguments = payload[:-1].split(b"\0")
    arguments = [value.decode("utf-8", errors="strict") for value in raw_arguments]
    if not arguments or not arguments[0]:
        raise ValueError("argv payload has no command")
    return arguments


def resolve_python_script(arguments: list[str]) -> list[str]:
    """Use the active EIM Python for .py commands, especially idf.py on Windows."""

    command = arguments[0]
    if not command.lower().endswith(".py"):
        return arguments

    resolved = command
    if not os.path.isfile(resolved):
        resolved = shutil.which(command) or command
    if not os.path.isfile(resolved):
        return arguments
    return [sys.executable, resolved, *arguments[1:]]


def main() -> int:
    if len(sys.argv) != 2:
        return fail("用法: eim-argv-runner.py <argv-file>")

    argv_path = Path(sys.argv[1])
    try:
        arguments = read_argv(argv_path)
    except (OSError, UnicodeError, ValueError) as exc:
        return fail(f"无法读取安全 argv 文件: {exc}")
    finally:
        # The caller also has a cleanup trap.  Removing here minimizes the time
        # potentially sensitive arguments remain on disk and survives exec().
        try:
            argv_path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            print(f"WARN=无法删除 argv 临时文件: {exc}", file=sys.stderr)

    arguments = resolve_python_script(arguments)
    try:
        os.execvpe(arguments[0], arguments, os.environ.copy())
    except FileNotFoundError:
        return fail(f"命令不存在: {arguments[0]}", 127)
    except PermissionError:
        return fail(f"命令不可执行: {arguments[0]}", 126)
    except OSError as exc:
        return fail(f"启动命令失败: {exc}", 126)


if __name__ == "__main__":
    raise SystemExit(main())
