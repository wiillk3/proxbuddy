"""Send Python print() to C stdout so ProxBuddy's terminal can capture it.

CPython-for-iOS redirects sys.stdout/stderr to Apple's os_log. Short lines
never appear in the pm3 terminal; oversized lines fail over with:

    Logging Error: Failed to receive 1 log messages.
    Please review standard output for possible log message content.
"""
import sys


def _rebind_stdio() -> None:
    try:
        stdout = open(1, "w", encoding="utf-8", buffering=1, closefd=False)
        stderr = open(2, "w", encoding="utf-8", buffering=1, closefd=False)
    except OSError:
        return
    sys.stdout = stdout
    sys.stderr = stderr
    sys.__stdout__ = stdout
    sys.__stderr__ = stderr


_rebind_stdio()
