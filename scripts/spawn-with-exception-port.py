"""Run a command the way an application with a crash reporter starts it (macOS).

Usage: spawn-with-exception-port.py SECONDS COMMAND [ARG...]

The child gets a task exception port for BAD_ACCESS, BAD_INSTRUCTION,
ARITHMETIC and BREAKPOINT that nothing services, as a parent with an
in-process crash reporter hands its own port to the processes it starts
(Zed does). An SBCL that keeps the port blocks on its first trap (brk), so
the command never finishes.

Exit status: the command's, or 124 when it did not finish within SECONDS
(it is then killed).
"""
import ctypes
import os
import platform
import signal
import sys
import time

EXC_MASK = 0x02 | 0x04 | 0x08 | 0x40  # BAD_ACCESS BAD_INSTRUCTION ARITHMETIC BREAKPOINT
EXCEPTION_DEFAULT = 1
THREAD_STATE_NONE = 5 if platform.machine() == "arm64" else 13
MACH_PORT_RIGHT_RECEIVE = 1
MACH_MSG_TYPE_MAKE_SEND = 20


def main():
    seconds = float(sys.argv[1])
    argv = [a.encode() for a in sys.argv[2:]]
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    task = ctypes.c_uint.in_dll(libc, "mach_task_self_").value
    port = ctypes.c_uint()
    if libc.mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, ctypes.byref(port)):
        sys.exit("mach_port_allocate failed")
    if libc.mach_port_insert_right(task, port.value, port.value, MACH_MSG_TYPE_MAKE_SEND):
        sys.exit("mach_port_insert_right failed")
    attr = ctypes.c_void_p()
    libc.posix_spawnattr_init(ctypes.byref(attr))
    if libc.posix_spawnattr_setexceptionports_np(
            ctypes.byref(attr), ctypes.c_uint(EXC_MASK), ctypes.c_uint(port.value),
            ctypes.c_int(EXCEPTION_DEFAULT), ctypes.c_int(THREAD_STATE_NONE)):
        sys.exit("posix_spawnattr_setexceptionports_np failed")
    cargv = (ctypes.c_char_p * (len(argv) + 1))(*argv, None)
    env = [f"{k}={v}".encode() for k, v in os.environ.items()]
    cenv = (ctypes.c_char_p * (len(env) + 1))(*env, None)
    pid = ctypes.c_int()
    err = libc.posix_spawnp(ctypes.byref(pid), argv[0], None, ctypes.byref(attr), cargv, cenv)
    if err:
        sys.exit(f"posix_spawnp: {os.strerror(err)}")
    deadline = time.time() + seconds
    while time.time() < deadline:
        done, status = os.waitpid(pid.value, os.WNOHANG)
        if done:
            sys.exit(os.waitstatus_to_exitcode(status))
        time.sleep(0.2)
    os.kill(pid.value, signal.SIGKILL)
    os.waitpid(pid.value, 0)
    print(f"spawn-with-exception-port: {sys.argv[2]} did not finish in {seconds:g} s",
          file=sys.stderr)
    sys.exit(124)


if __name__ == "__main__":
    main()
