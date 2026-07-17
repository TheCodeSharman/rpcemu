{
  description = "RPCEmu Freeway host tooling — udp-broadcast-relay-redux package, freeway-net helper, and the rpcemu-freeway NixOS module. Pairs with the feature/iptunnel-persistent-tap patch to run RPCEmu iptunnelling networking fully unprivileged.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          relay = pkgs.callPackage ./nix/udp-broadcast-relay-redux.nix { };
        in
        {
          udp-broadcast-relay-redux = relay;
          default = relay;

          # `nix run .#freeway-net -- up|relay|status|down` — the manual host
          # setup helper, wrapped with its runtime deps (ip, iptables, relay).
          freeway-net = pkgs.writeShellApplication {
            name = "freeway-net";
            runtimeInputs = [ pkgs.iproute2 pkgs.iptables pkgs.procps relay ];
            text = builtins.readFile ./tools/freeway-net.sh;
          };
        });

      apps = forAllSystems (pkgs: {
        udp-broadcast-relay-redux = {
          type = "app";
          program = "${self.packages.${pkgs.system}.udp-broadcast-relay-redux}/bin/udp-broadcast-relay-redux";
        };
        freeway-net = {
          type = "app";
          program = "${self.packages.${pkgs.system}.freeway-net}/bin/freeway-net";
        };
      });

      # Declarative deployment: persistent tap + proxy-ARP + broadcast relay,
      # so a patched RPCEmu attaches to the tap unprivileged. See nix/.
      nixosModules.rpcemu-freeway = import ./nix/rpcemu-freeway.nix;
    };
}
