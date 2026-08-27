{ pkgs, lib, ... }:

# Reproducible build/run environment for the RPCEmu Qt5 interpreter.
#
# This file lives on the `lab` branch — the build infrastructure, which sits
# OUTSIDE the source it builds (the source is a nested worktree at tree/). So it
# is never in a feature branch and never in a `git diff upstream feature/X`
# upstream-submission diff. direnv searches parent directories, so this
# environment applies inside tree/ too, whatever branch tree/ is on.
#
# Setup:  tools/bootstrap.sh   (creates tree/; idempotent, re-run any time)
# Build:  make                 (top-level wrapper; pins -std=gnu17 for gcc15/C23)
# Run:    make run             (launches installs/<NAME>/; NOT the source root)
{
  name = "rpcemu";

  packages = with pkgs; [
    # Build toolchain
    gnumake
    pkg-config

    # Qt5 — the .pro pulls in `core widgets gui multimedia`.
    # qmake itself lives in the `dev` output, the libraries in the default one;
    # both are needed, and qtmultimedia's `dev` carries the qt_lib_multimedia.pri
    # that `QT += multimedia` resolves against.
    qt5.qtbase
    qt5.qtbase.bin      # platform plugins (cocoa / xcb) live in the bin output
    qt5.qtbase.dev
    qt5.qtmultimedia
    qt5.qtmultimedia.dev

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
  ]

  # --- Linux-only -----------------------------------------------------------
  # The X11/Wayland stack the Qt platform plugins need. macOS uses the cocoa
  # plugin, which is compiled into qtbase and needs none of this.
  ++ lib.optionals stdenv.isLinux [
    qt5.qtwayland      # Wayland desktop; we still force xcb at runtime

    # X11 — keyboard_x.c is the X11 keycode table. macOS builds
    # keyboard_macosx.c (Carbon virtual keys) instead, so this is Linux-only.
    xorg.libX11
    xorg.libXext

    # The Qt xcb platform plugin dlopens libxcb-cursor at runtime
    xcb-util-cursor
  ]

  # --- macOS-only -----------------------------------------------------------
  # qmake shells out to `xcrun` to locate the platform SDK; with none in the
  # environment it dies with "Cannot run compiler ... unable to find sdk:
  # 'macosx'". Taking the SDK from nixpkgs keeps the shell hermetic (no
  # dependency on whichever Xcode happens to be installed) and pins SDK 14 —
  # the version Qt 5.15 was tested against, so it also silences qmake's
  # "you're using 15 ... unsupported configuration" warning.
  ++ lib.optionals stdenv.isDarwin [
    apple-sdk
  ];

  # C/C++ toolchain (gcc) + stdenv niceties
  languages.c.enable = true;
  languages.cplusplus.enable = true;

  # Qt platform + plugin paths.
  #
  # QT_QPA_PLATFORM: on Linux RPCEmu is an X11 app, so on a Wayland session we
  # force the xcb plugin (matches the fork CLAUDE.md's run note). macOS has
  # exactly one platform plugin, cocoa, compiled into qtbase — setting this
  # there could only break it, so it is Linux-only.
  #
  # QT_PLUGIN_PATH: Qt5 Multimedia's audio backends live in qtmultimedia's OWN
  # store path, which Qt's compiled-in (qtbase-only) plugin search never covers
  # — so in a bare devshell (no wrapQtAppsHook) QAudioOutput finds no backend
  # and RPCEmu logs "Failed to create QAudioOutput, no audio". Point
  # QT_PLUGIN_PATH at qtmultimedia (and, on Linux, qtwayland) so the audio +
  # native-Wayland plugins load; xcb still resolves from qtbase's compiled-in
  # default path.
  env = {
    QT_PLUGIN_PATH = lib.concatStringsSep ":" (
      [
        # The PLATFORM plugin (cocoa on macOS, xcb on Linux) is in qtbase's
        # `bin` output, NOT the default one -- which holds only lib/ and
        # share/. Without this Qt aborts at startup with "Could not find the
        # Qt platform plugin \"cocoa\" in \"\"", and the abort surfaces as a
        # macOS crash reporter dialog rather than a readable error.
        "${pkgs.qt5.qtbase.bin}/lib/qt-${pkgs.qt5.qtbase.version}/plugins"
        "${pkgs.qt5.qtmultimedia}/lib/qt-${pkgs.qt5.qtbase.version}/plugins"
      ]
      ++ lib.optional pkgs.stdenv.isLinux
           "${pkgs.qt5.qtwayland}/lib/qt-${pkgs.qt5.qtbase.version}/plugins"
    );
  } // lib.optionalAttrs pkgs.stdenv.isLinux {
    QT_QPA_PLATFORM = "xcb";
  };

  enterShell = ''
    echo "rpcemu devenv  —  qmake $(qmake -query QT_VERSION 2>/dev/null || echo '(not found)')"
    echo "  build:  make        (top-level wrapper; pins -std=gnu17 for gcc15)"
    echo "  run:    make run     (launches an install; NAME=riscos-530 to pick)"
  '';
}
