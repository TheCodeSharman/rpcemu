# RPCEmu Freeway host networking (NixOS module).
#
# Puts an RPCEmu guest onto the physical LAN so Acorn Access / Freeway (ShareFS
# over AUN) works between RPCEmu and a real RISC PC — over WiFi, where a true L2
# bridge is impossible (the AP won't forward frames for the emulated MAC).
#
# It routes at L3 with the kernel's own proxy-ARP (so the guest's IP appears to
# the LAN to live behind this host's uplink) and relays the Freeway discovery
# broadcasts (UDP 32770) between the uplink and the tap with
# udp-broadcast-relay-redux (forging the sender so replies come straight back).
#
# RUNTIME DEPENDENCY: this pairs with the `feature/iptunnel-persistent-tap`
# patch. It pre-creates a persistent, user-owned tap that the *patched* RPCEmu
# attaches to unprivileged (rpc.cfg: network_type=iptunnelling,
# tunnelinterface=<tap>). Without that patch RPCEmu ignores `tunnelinterface`,
# makes its own tap as root, and this tap sits unused. On the fork's
# `integration` branch both features are present, so it just works.
#
# Self-contained: builds the relay via callPackage, so the module can be
# exported straight from this repo's flake with no cross-flake plumbing.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.rpcemu-freeway;
  relay = pkgs.callPackage ./udp-broadcast-relay-redux.nix { };

  setup = pkgs.writeShellScript "rpcemu-freeway-up" ''
    set -eu
    ip=${pkgs.iproute2}/bin/ip

    # Persistent tap owned by the RPCEmu user, so RPCEmu attaches unprivileged.
    $ip tuntap add dev ${cfg.tap} mode tap user ${cfg.owner} 2>/dev/null || true
    $ip link set ${cfg.tap} up

    # /32 with an explicit broadcast: gives the relay a valid SIOCGIFBRDADDR
    # ($broadcast) without adding a LAN-subnet route via the tap that would
    # steal the uplink's traffic. A single /32 host route reaches the guest.
    $ip addr replace ${cfg.tapAddress}/32 broadcast ${cfg.broadcast} dev ${cfg.tap}
    $ip route replace ${cfg.guestAddress}/32 dev ${cfg.tap}

    # Proxy-ARP both ways so the guest is a reachable LAN peer; loose rp_filter.
    for i in ${cfg.uplink} ${cfg.tap}; do
      echo 1 > /proc/sys/net/ipv4/conf/$i/proxy_arp
      echo 2 > /proc/sys/net/ipv4/conf/$i/rp_filter
    done
  '';
in
{
  options.services.rpcemu-freeway = {
    enable = lib.mkEnableOption
      "RPCEmu Freeway host networking (persistent tap + proxy-ARP + AUN broadcast relay)";

    uplink = lib.mkOption {
      type = lib.types.str;
      example = "wlp0s20f3";
      description = "Host LAN uplink interface (the WiFi device on the same subnet as the real RISC PC).";
    };

    owner = lib.mkOption {
      type = lib.types.str;
      example = "msharman";
      description = "User that owns the tap and runs RPCEmu.";
    };

    tap = lib.mkOption {
      type = lib.types.str;
      default = "rpctap0";
      description = "Persistent tap device RPCEmu attaches to (matches rpc.cfg tunnelinterface).";
    };

    tapAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.88.11";
      description = "Host end of the tap link; a free address on the LAN subnet.";
    };

    guestAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.88.12";
      description = "The RISC OS guest's LAN address (set inside RISC OS too).";
    };

    broadcast = lib.mkOption {
      type = lib.types.str;
      default = "192.168.88.255";
      description = "LAN broadcast address.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 32770;
      description = "Freeway discovery UDP broadcast port to relay (observed from the real RISC PC).";
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Log every relayed packet to the journal (noisy; useful while bringing Freeway up).";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # Broadcast discovery terminates on the relay's own socket on THIS host, so
    # it must pass the INPUT firewall (unlike the guest's forwarded traffic,
    # which is unrestricted). Accept ALL udp broadcast (any port) so the relay
    # never misses a discovery port; unicast-to-host stays filtered. Also allow
    # forwarding between the uplink and the tap.
    networking.firewall.extraCommands = ''
      iptables -I INPUT -p udp -m addrtype --dst-type BROADCAST -j ACCEPT
      iptables -I FORWARD -i ${cfg.tap} -o ${cfg.uplink} -j ACCEPT
      iptables -I FORWARD -i ${cfg.uplink} -o ${cfg.tap} -j ACCEPT
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D INPUT -p udp -m addrtype --dst-type BROADCAST -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i ${cfg.tap} -o ${cfg.uplink} -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i ${cfg.uplink} -o ${cfg.tap} -j ACCEPT 2>/dev/null || true
    '';

    systemd.services.rpcemu-freeway = {
      description = "RPCEmu Freeway: persistent tap + proxy-ARP + Access/Freeway broadcast relay";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        # Bring up the tap / routing / proxy-ARP, then run the relay as the main
        # process. The tap is intentionally left in place on stop (it is
        # persistent) so a relay restart never yanks it out from under RPCEmu.
        ExecStartPre = setup;
        ExecStart = "${relay}/bin/udp-broadcast-relay-redux "
          + lib.optionalString cfg.debug "-d "
          + "--id 1 --port ${toString cfg.port} --dev ${cfg.uplink} --dev ${cfg.tap}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
