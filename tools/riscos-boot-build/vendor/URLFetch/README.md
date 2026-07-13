# vendor/URLFetch — URL fetcher protocol modules

`Modules/` holds five URL-scheme *fetcher* modules that plug into the `URL`
(`URL_Fetcher`) module and let URL-aware apps resolve non-HTTP schemes:

| Module | Provides | Version | Scheme |
|--------|----------|---------|--------|
| `File,ffa`   | `FileFetcher`   | File Fetcher 0.49 (25 Sep 2018) | `file:` — **local disc** |
| `FTP,ffa`    | `FTPFetcher`    | 2020 rebuild                    | `ftp:`   |
| `Finger,ffa` | `FingerFetcher` | Acorn 1998                      | `finger:`|
| `Gopher,ffa` | `GopherFetcher` | Acorn 1998                      | `gopher:`|
| `WhoIs,ffa`  | `WhoIsFetcher`  | Acorn 1998                      | `whois:` |

They are **© Acorn 1997-8** with later ROOL-lineage rebuilds; redistributable.

## Why vendored (not downloaded)

HardDisc4 + PlingSystem (our pinned *authoritative* sources) ship only the
`URL` (`URL_Fetcher`), `AcornHTTP` and `AcornSSL` modules under
`!System.Modules.Network.URL.` — **not** the protocol fetchers above. The only
archive that carried them was the **marutan.net RPCEmu 3.71 Easy-Start bundle**,
which was deliberately dropped as a source (commit `d2bd42c`) because it was *"a
Google-Drive image of a real StrongARM machine — the murkiest provenance of any
source"* and its pin was a rot-prone Google-Drive URL. Dropping it (to keep the
disc's apps fully-authoritative) also removed these fetchers.

Rather than re-introduce that whole murky, fragile-URL source for a handful of
tiny modules, the five redistributable fetcher modules are vendored here (same
rationale as `vendor/PackMan/` and `vendor/PkgDisc/` — redistributable binaries
with no clean, pinnable standalone download). This isolates the only
murky-provenance bytes to a small, auditable, version-stamped set. The bytes are
identical to those in a known-good RISC OS 3.71 install.

**Deliberately excluded:** the bundle's `HTTP,ffa` (*Acorn HTTP 0.84, 1998*) — a
stale duplicate of the newer, authoritative `AcornHTTP` we already ship. Two
`http:` fetchers would clash if loaded; `AcornHTTP` supersedes it.

## Who needs `File` (the reason this exists)

`Manuals.!Bookworm` — Acorn's **local HTML reader**. Its `!Run` does:

    RMEnsure FileFetcher 0.16  RMLoad System:Modules.Network.URL.File
    RMEnsure FileFetcher 0.16  Error You need FileFetcher 0.16 or later to run Bookworm

Without `File`, Bookworm aborts with *"System:Modules.Network.URL.File not
found"*. 0.49 ≫ the 0.16 minimum. The other four fetchers are future-proofing
(new URL schemes), inert unless an app RMLoads them.

## How the build places them

`sources.json` → `placements`:

    { "repo": "tools/riscos-boot-build/vendor/URLFetch/Modules",
      "to":   "!Boot/Resources/!System/310/Modules/Network/URL" }

`copytree(..., dirs_exist_ok=True)` merges the five `,ffa` modules into the
existing `URL` directory (310 set) alongside our authoritative `URL`,
`AcornHTTP`, `AcornSSL`. The placement points at `Modules/` (not the vendor
root) so this README is **not** copied onto the disc — mirroring `vendor/PackMan`.
