{ pkgs, lib, ... }:

# Reproducible build/run environment for the RPCEmu Qt5 interpreter.
#
# This file lives on the `upstream` branch (like .gitignore / CLAUDE.md /
# tools/reintegrate.sh) so it is present on every branch — including the
# derived `integration` branch consumers build from — yet stays OUT of the
# `git diff upstream feature/X` upstream-submission diffs.
#
# Build:  make            (top-level wrapper; pins -std=gnu17 for gcc15/C23)
# Run:    make run        (or ./rpcemu-interpreter directly; needs a .rom in roms/)
{
  name = "rpcemu";

  packages = with pkgs; [
    # Build toolchain
    gnumake
    pkg-config

    # Qt5 — the .pro pulls in `core widgets gui multimedia`
    qt5.qtbase
    qt5.qtmultimedia
    qt5.qtwayland      # Wayland desktop; we still force xcb at runtime

    # X11 — keyboard_x.c / rpc-linux.c link against libX11
    xorg.libX11
    xorg.libXext

    # The Qt xcb platform plugin dlopens libxcb-cursor at runtime
    xcb-util-cursor

    # Test frameworks (project policy: ALL dev tooling lives here, not
    # vendored or provisioned ad-hoc per test — see CLAUDE.md)
    criterion        # C unit tests (tests/unit/, on feature/ide-tests)

    # Dev tools
    git-branchless   # stacked-branch mgmt (git sl / sync / move). Its git hooks
                     # (installed by `git branchless init`) call this binary, so it
                     # must be on PATH whenever working in the repo — hence here.

    # MCP server runtime (tools/mcp/rpcemu_mcp.py, on feature/spork-mcp-server):
    # a standalone Python tool that lets an MCP client (Claude Code, Claude
    # Desktop, …) drive a RISC OS guest via HostCmd + HostFS. Provided from Nix
    # rather than pip because pydantic-core's wheels are unreliable on NixOS, and
    # so the whole fork stays reproducible in one shell. `ps.mcp` supplies the
    # FastMCP API the server imports; the tool's own requirements.txt stays the
    # portable, upstream-facing pip install story.
    #
    # pytest drives the end-to-end suite in tests/e2e/ (on feature/e2e-tests).
    (python3.withPackages (ps: [ ps.mcp ps.pytest ]))
  ];

  # C/C++ toolchain (gcc) + stdenv niceties
  languages.c.enable = true;
  languages.cplusplus.enable = true;

  # RPCEmu is an X11 app; on a Wayland session force the xcb platform plugin
  # (matches the fork CLAUDE.md's run note).
  env.QT_QPA_PLATFORM = "xcb";

  # Qt5 Multimedia's audio backends (ALSA/pulse) live in qtmultimedia's OWN
  # store path, which Qt's compiled-in (qtbase-only) plugin search never covers
  # — so in a bare devshell (no wrapQtAppsHook) QAudioOutput finds no backend
  # and RPCEmu logs "Failed to create QAudioOutput, no audio". Point
  # QT_PLUGIN_PATH at qtmultimedia (and qtwayland) so the audio + native-Wayland
  # plugins load; xcb still resolves from qtbase's compiled-in default path.
  env.QT_PLUGIN_PATH =
    "${pkgs.qt5.qtmultimedia}/lib/qt-${pkgs.qt5.qtbase.version}/plugins:" +
    "${pkgs.qt5.qtwayland}/lib/qt-${pkgs.qt5.qtbase.version}/plugins";

  enterShell = ''
    echo "rpcemu devenv  —  qmake $(qmake -query QT_VERSION 2>/dev/null || echo '(not found)')"
    echo "  build:  make        (top-level wrapper; pins -std=gnu17 for gcc15)"
    echo "  run:    make run     (drop a .rom into roms/ first)"
  '';
}
