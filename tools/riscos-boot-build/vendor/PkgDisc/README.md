# Pkg — pristine `!Packages` on a RaFS volume

`Pkg/` is a **RaFS 1.16 disc** (disc name `Pkg`) containing a fresh, empty
`!Packages` database. It's placed at `!Boot.Resources.Pkg` and mounted on demand
by PackMan's `!Run` (see `../PackMan/`), which then sets
`Packages$Dir = RaFS::Pkg.$.!Packages`.

## Why

RISC OS 3.7 FileCore is limited to **10-character** leafnames, but PackMan's
`!Packages` uses long package names for both `Info/` (e.g. `PipeDream-Examples`,
`SharedUnixLibrary`) and `Cache/` (full archive filenames) — and LibPkg builds
every path under `<Packages$Dir>` with no separate Cache/Info override. So the
whole `!Packages` has to live on a long-filename filing system. RaFS provides
that (it stores the tree as short-named zone files under `A0/` plus its own
long-name directory tables), reached via an explicit `RaFS::…` path — which also
sidesteps the fact that RaFS isn't transparent at a FileCore subdirectory.

RaFS is loaded and this disc mounted **only when PackMan launches** — never at
boot (its `!RaFS.!Boot` only sets variables; the module isn't `RMLoad`ed until a
mount). So RaFS stays off the boot path.

## Provenance

Authored in RPCEmu: `*raFS_Create <Boot$Dir>.Resources.Pkg Pkg`, `*Mount …`,
copied PackMan's template `!Packages` in, `*Dismount Pkg` to flush, then captured
here (read read-only from the FileCore `hd4` image with the `adfs` driver, so the
`,xxx` filetypes on the RaFS zone files are preserved). It is a **pristine, empty**
package database — no packages installed. The container's `!Mount` had its trailing
`Filer_OpenDir` line removed so mounting from PackMan doesn't pop a window.

Regenerate by repeating the RPCEmu steps and re-capturing this directory.
