---
name: dev-build-logs
description: Read before looking for SupaLogger lines of the installed dev build in `log show`; the dev build is Debug and logs to stdout only.
---

# The installed dev build does not write to the unified log

`make install-dev-build` installs a Debug build. In DEBUG, `SupaLogger` only `print`s to stdout;
`os.Logger` (subsystem `app.supabit.supacode`, category per logger, e.g. `RemoteAccess`) is used
in Release only. So `log show --predicate 'category == "RemoteAccess"'` returns nothing for the
app in `/Applications`, and an empty result there proves nothing.

For live checks of the installed dev build use evidence that does not need its log: listening
ports (`lsof -nP -iTCP -sTCP:LISTEN | grep -i supacode`), files the app creates (for example
`<config>/remote-lan/identity.p12`), the phone's UI, or the relay's `wrangler tail`.
**Why:** on 2026-11-04 a live LAN check found zero RemoteAccess lines and first suspected the
host had not started.
