# udp-broadcast-relay-redux isn't in nixpkgs; build it from upstream.
# Relays UDP broadcasts between interfaces, forging the original sender — used
# by the rpcemu-freeway module to carry Acorn Access/Freeway discovery
# broadcasts (UDP 32770) between the host uplink and the RPCEmu tap.
{ lib, stdenv, fetchFromGitHub }:

stdenv.mkDerivation {
  pname = "udp-broadcast-relay-redux";
  version = "0-unstable-2024";

  src = fetchFromGitHub {
    owner = "marjohn56";
    repo = "udp-broadcast-relay-redux";
    rev = "d1b76c92332409c1f6276c19a585d2b9d0f83f10";
    hash = "sha256-03ewu9A5AUucnZqN3iXaJndWnUCWlAG4uKtZUjT0mRY=";
  };

  # time() is used without <time.h>; under gcc's C23 default the implicit
  # declaration is a hard error, so add the include before building.
  postPatch = ''
    sed -i '/#include <stdio.h>/a #include <time.h>' main.c
  '';

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o udp-broadcast-relay-redux main.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 udp-broadcast-relay-redux $out/bin/udp-broadcast-relay-redux
    runHook postInstall
  '';

  meta = {
    description = "Relay UDP broadcasts between interfaces, forging the sender (RPCEmu Freeway/AUN discovery)";
    homepage = "https://github.com/marjohn56/udp-broadcast-relay-redux";
    license = lib.licenses.gpl2Only;
    mainProgram = "udp-broadcast-relay-redux";
    platforms = lib.platforms.linux;
  };
}
