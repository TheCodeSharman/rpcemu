# PackMan 0.9.7-1 (vendored — 26-bit-capable)

`!PackMan` here is **PackMan 0.9.7-1** by Alan Buckley, vendored because it is
the newest release that actually runs on **26-bit RISC OS 3.7** (verified on a
real RISC PC). It is the copy that ships pre-installed in RPCEmu's bundled
RISC OS 3.71 quick-start image.

## Why not download it like the other sources?

The build normally pins each source to a URL + sha256 (`sources.json`). PackMan
can't be: the ROOL package repo (`packages.riscosopen.org`) only ever serves the
**latest** build (currently **0.9.8-1**), and the GitHub `v0.9.7` release tag has
**no built asset** (source only). So there is no stable URL for a clean 0.9.7 zip
— hence it's vendored here and placed via a `repo` entry, exactly like `!raFS`.

## The 0.9.8 regression

0.9.8-1 (the ROOL-repo latest) **fails to load on 26-bit** with *"No writeable
memory at this address"* — verified on **both RISC OS 3.7 and 4.02** (both are
26-bit), so the 0.9.7 pin holds for *any* disc that serves a 26-bit OS, including
the F-format 4.02/5.30 card. Only a 32-bit-only (RO5-solely) disc could use 0.9.8.
Both 0.9.7 and 0.9.8 are GCCSDK/UnixLib C++ builds
carrying an AIF address-mode of 32, so the AIF flag is **not** the discriminator
— 0.9.7 is 26/32-neutral in practice and 0.9.8 regressed (a newer GCCSDK /
SharedUnixLibrary that dropped 26-bit neutrality). The package's `Environment:
arm` tag claims "all ARM machines", which 0.9.8 no longer honours on 26-bit —
i.e. an upstream packaging error, not something on our side.

## Local modification: `!Run` RaFS-mount hook

`!PackMan/!Run` carries a small marked block (`--- riscos-boot-build … ---`) that,
**on launch only**, mounts a RaFS disc at `!Boot.Resources.Pkg` (disc name `Pkg`)
and points `Packages$Dir` at `RaFS::Pkg.$.!Packages`. This gives the package
database (Cache + Info) long filenames on 26-bit FileCore, without loading RaFS at
boot — RISC OS 3.7 FileCore is 10-char, and PackMan builds all its paths under
`<Packages$Dir>` (no separate Cache/Info override exists). The block is
`IfThere`-guarded, so it's a no-op until the RaFS disc is created; PackMan then
falls back to its bundled `!Packages`. Create the disc in RPCEmu (`raFS_Create`),
drop `!Packages` inside it, name it `Pkg`, and place it at `!Boot.Resources.Pkg`.

## Provenance

Copied from `~/Projects/rpcemu/installs/riscos-371/hostfs/Apps/Admin/!PackMan`.
PackMan's mutable state (Choices, Sources, package DB) lives **outside** the app
dir (in `!Boot.Choices.PackMan` and `!Boot.Resources.!Packages`), so this app
directory is pristine. Licence: Apache-2.0 (see `!PackMan/LICENSE`).
