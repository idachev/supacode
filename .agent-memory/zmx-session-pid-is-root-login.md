---
name: zmx-session-pid-is-root-login
description: Read before inspecting a zmx session's process (tty, pid info): its pid is setuid-root /usr/bin/login, so proc_pidinfo fails with EPERM.
paths:
  - supacode/Features/RemoteAccess/ZmxRemoteStream.swift
  - supacode/Clients/Zmx/**
---

# The zmx session pid is root-owned `/usr/bin/login`

zmx `Info` returns the pid of the session's first process, which in Supacode is `/usr/bin/login`
(setuid root; the shell is its child). `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` on it returns 0 with
errno EPERM from the app, so any code that reads the controlling tty that way silently gets nil.
Use `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid])` → `kinfo_proc.kp_eproc.e_tdev` (what `ps` uses);
the tty device itself is owned by the user and opens fine.

**Why:** on 2026-11-10 remote `size` frames were never sent: `ptySize` was always nil, and `attached`
silently fell back to the app grid, so a resize showed only after a page refresh.
Check: `ps -o user=,comm= -p <Info pid>` shows `root /usr/bin/login`.
