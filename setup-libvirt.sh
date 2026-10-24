#!/usr/bin/env bash
#
# setup-libvirt.sh
# Idempotent setup of libvirt + QEMU/KVM + virt-manager on Fedora for a
# NON-ROOT user (via the "libvirt" group and qemu:///system).
#
# - Never deletes VMs, disk images or networks.
# - Only restarts networks when needed, and asks first if VMs are attached.
# - Run as your normal user (NOT with sudo); it calls sudo itself.
#
# Usage:
#   ./setup-libvirt.sh            # interactive
#   ./setup-libvirt.sh --yes      # answer "yes" to all questions
#   FIREWALL_BACKEND=nftables ./setup-libvirt.sh   # or iptables
#
# FIREWALL_BACKEND unset = leave /etc/libvirt/network.conf as it is.
# On Fedora (firewalld uses nftables) "nftables" is the recommended backend.

set -Eeuo pipefail
export LC_ALL=C.UTF-8   # parse virsh / firewall-cmd output in English

FIREWALL_BACKEND="${FIREWALL_BACKEND:-}"
ASSUME_YES=0
URI="qemu:///system"
NETCONF=/etc/libvirt/network.conf
TARGET_USER="$USER"

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 2 ;;
  esac
done

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '    \033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "Command failed (line $LINENO): $BASH_COMMAND"' ERR

# confirm "question" [y|n]  -> default answer; --yes answers yes;
# without a terminal the default is used.
confirm() {
  local q=$1 def=${2:-n} ans hint="[y/N]"
  [[ $def == y ]] && hint="[Y/n]"
  (( ASSUME_YES )) && return 0
  if [[ ! -t 0 ]]; then
    warn "No terminal - using default (${def^^}) for: $q"
    [[ $def == y ]]; return
  fi
  read -r -p "    ? $q $hint " ans || ans=""
  ans=${ans:-$def}
  [[ ${ans,,} == y || ${ans,,} == yes ]]
}

v() { sudo virsh -q -c "$URI" "$@"; }   # sudo: new group may not be active yet

active_nets() { local o; o=$(v net-list --name); sed '/^$/d' <<<"$o"; }
is_active()   { local o; o=$(active_nets); grep -qx -- "$1" <<<"$o"; }

net_bridge() {
  local x; x=$(v net-dumpxml "$1")
  sed -n "s/.*<bridge name='\([^']*\)'.*/\1/p" <<<"$x"
}

net_mode() {   # nat | route | open | isolated | bridge | macvtap | ...
  local x m; x=$(v net-dumpxml "$1")
  m=$(sed -n "s/.*<forward[^>]*mode='\([^']*\)'.*/\1/p" <<<"$x")
  if [[ -z $m ]]; then
    if grep -q '<forward' <<<"$x"; then m=nat; else m=isolated; fi
  fi
  echo "$m"
}

# Bridges libvirt creates itself (not host bridges like br0)
libvirt_owned() { case "$(net_mode "$1")" in nat|route|open|isolated) return 0 ;; *) return 1 ;; esac; }

vms_on_net() {   # running VMs with a NIC on network $1
  local doms dom ifl
  doms=$(v list --name)
  while read -r dom; do
    [[ -z $dom ]] && continue
    ifl=$(v domiflist "$dom")
    if awk -v n="$1" '$2=="network" && $3==n {f=1} END {exit !f}' <<<"$ifl"; then
      echo "$dom"
    fi
  done <<<"$doms"
}

firewalld_active() { systemctl is-active --quiet firewalld; }

# ---------------------------------------------------------------------------
info "Pre-flight checks"
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then die "Run this as your normal user, not as root / with sudo."; fi
grep -qi fedora /etc/os-release || die "This script is meant for Fedora."
grep -qE 'vmx|svm' /proc/cpuinfo \
  || die "No vmx/svm CPU flags. Enable VT-x / AMD-V (SVM) in the BIOS/UEFI first."
ok "CPU virtualization extensions present"
sudo -v || die "sudo is required."

# ---------------------------------------------------------------------------
info "Installing virtualization packages"
# ---------------------------------------------------------------------------
sudo dnf install -y @virtualization \
  libvirt-daemon-config-network libvirt-daemon-kvm \
  virt-manager virt-install virt-viewer \
  iptables-nft nftables python3
ok "Packages installed"

# ---------------------------------------------------------------------------
info "libvirt daemons (modular, Fedora default)"
# ---------------------------------------------------------------------------
mono=()
for unit in libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket \
            libvirtd-tcp.socket libvirtd-tls.socket; do
  if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
    mono+=("$unit")
  fi
done
if (( ${#mono[@]} )); then
  warn "Monolithic libvirtd is enabled/active: ${mono[*]}"
  warn "It conflicts with the modular daemons. Running VMs keep running."
  if confirm "Disable libvirtd and use the modular daemons?" y; then
    sudo systemctl disable --now "${mono[@]}"
    ok "Monolithic libvirtd disabled"
  else
    die "Aborted: libvirtd and the modular daemons must not run side by side."
  fi
fi
for drv in qemu network nodedev nwfilter secret storage interface; do
  sudo systemctl enable --now "virt${drv}d.socket" "virt${drv}d-ro.socket" "virt${drv}d-admin.socket"
done
ok "Modular daemon sockets enabled"

# ---------------------------------------------------------------------------
info "Firewall backend"
# ---------------------------------------------------------------------------
CUR_BACKEND=$(sudo sed -n -E 's/^[[:space:]]*firewall_backend[[:space:]]*=[[:space:]]*"?([a-z]+)"?.*/\1/p' "$NETCONF" 2>/dev/null | tail -n1 || true)
EFFECTIVE=${CUR_BACKEND:-nftables}
BACKEND_CHANGED=0

if [[ -n $FIREWALL_BACKEND ]]; then
  [[ $FIREWALL_BACKEND == iptables || $FIREWALL_BACKEND == nftables ]] \
    || die "FIREWALL_BACKEND must be 'iptables' or 'nftables'."
  if [[ $FIREWALL_BACKEND == "$EFFECTIVE" ]]; then
    ok "Backend is already $EFFECTIVE - nothing to change"
  else
    if sudo grep -qE '^[[:space:]]*#?[[:space:]]*firewall_backend[[:space:]]*=' "$NETCONF"; then
      sudo sed -i -E "s|^[[:space:]]*#?[[:space:]]*firewall_backend[[:space:]]*=.*|firewall_backend = \"$FIREWALL_BACKEND\"|" "$NETCONF"
    else
      echo "firewall_backend = \"$FIREWALL_BACKEND\"" | sudo tee -a "$NETCONF" >/dev/null
    fi
    ok "Backend changed: $EFFECTIVE -> $FIREWALL_BACKEND"
    EFFECTIVE=$FIREWALL_BACKEND
    BACKEND_CHANGED=1
  fi
elif [[ -n $CUR_BACKEND ]]; then
  ok "Backend set in $NETCONF: $CUR_BACKEND (left unchanged)"
else
  ok "No backend configured - libvirt default (nftables on Fedora)"
fi

if [[ $EFFECTIVE == iptables ]] && firewalld_active; then
  warn "iptables backend + firewalld (nftables) can cause 'VM gets IP but no internet'."
  warn "Recommended: FIREWALL_BACKEND=nftables $0"
fi

if (( BACKEND_CHANGED )); then
  sudo systemctl restart virtnetworkd.service
  ok "virtnetworkd restarted with new backend"
else
  sudo systemctl start virtnetworkd.service
fi

# ---------------------------------------------------------------------------
info "Adding $TARGET_USER to the libvirt group"
# ---------------------------------------------------------------------------
NEED_RELOGIN=0
if [[ " $(id -nG "$TARGET_USER") " == *" libvirt "* ]]; then
  ok "$TARGET_USER is already in the libvirt group"
else
  sudo usermod -aG libvirt "$TARGET_USER"
  ok "$TARGET_USER added to the libvirt group"
  NEED_RELOGIN=1
fi

# ---------------------------------------------------------------------------
info "Default connection URI for virsh / virt-install"
# ---------------------------------------------------------------------------
CONF_FILE="$HOME/.config/libvirt/libvirt.conf"
mkdir -p "$(dirname "$CONF_FILE")"
if grep -qE '^\s*uri_default' "$CONF_FILE" 2>/dev/null; then
  sed -i -E "s|^\s*uri_default.*|uri_default = \"$URI\"|" "$CONF_FILE"
else
  echo "uri_default = \"$URI\"" >> "$CONF_FILE"
fi
ok "$CONF_FILE -> uri_default = \"$URI\""

# ---------------------------------------------------------------------------
info "libvirt networks"
# ---------------------------------------------------------------------------
if ! v net-info default &>/dev/null; then
  v net-define /usr/share/libvirt/networks/default.xml >/dev/null
  ok "Defined 'default' network"
fi
if is_active default; then
  ok "'default' network already active (not restarted)"
else
  v net-start default >/dev/null
  ok "'default' network started"
fi
v net-autostart default >/dev/null
ok "'default' network set to autostart"

# After a backend change ALL active networks need new firewall rules.
if (( BACKEND_CHANGED )); then
  mapfile -t nets < <(active_nets)
  attached=0
  warn "Firewall backend changed - these networks need a restart to get new rules:"
  for n in "${nets[@]}"; do
    vms=$(vms_on_net "$n" | paste -sd, - || true)
    printf '      %-20s running VMs: %s\n' "$n" "${vms:-none}"
    if [[ -n $vms ]]; then attached=1; fi
  done
  if (( attached )); then
    warn "Restarting cuts those VMs off. Afterwards they must be fully shut down"
    warn "and started again (a reboot inside the guest is not enough)."
  fi
  if (( ! attached )) || confirm "Restart these networks now?" n; then
    for n in "${nets[@]}"; do
      v net-destroy "$n" >/dev/null
      v net-start "$n" >/dev/null
    done
    ok "Networks restarted: ${nets[*]}"
  else
    warn "Not restarted. Networks keep their old firewall rules until restarted:"
    warn "  virsh net-destroy <net> && virsh net-start <net>"
  fi
fi

# ---------------------------------------------------------------------------
info "firewalld zones of libvirt bridges"
# ---------------------------------------------------------------------------
if ! firewalld_active; then
  warn "firewalld not running - skipping zone checks"
elif [[ " $(sudo firewall-cmd --get-zones) " != *" libvirt "* ]]; then
  warn "firewalld has no 'libvirt' zone (normally installed by libvirt). Try: sudo firewall-cmd --reload"
else
  perm_missing=()
  mapfile -t nets < <(active_nets)
  for n in "${nets[@]}"; do
    libvirt_owned "$n" || continue      # skip networks on host bridges (br0 etc.)
    br=$(net_bridge "$n")
    [[ -n $br ]] || continue
    rz=$(sudo firewall-cmd --get-zone-of-interface="$br" 2>/dev/null || true)
    pz=$(sudo firewall-cmd --permanent --get-zone-of-interface="$br" 2>/dev/null || true)
    if [[ $rz == libvirt ]]; then
      ok "$br ($n) is in zone 'libvirt'"
    else
      sudo firewall-cmd --zone=libvirt --change-interface="$br" >/dev/null
      warn "$br ($n) was in '${rz:-no zone}' -> moved to 'libvirt'"
    fi
    if [[ $pz != libvirt ]]; then perm_missing+=("$br"); fi
  done
  if (( ${#perm_missing[@]} )); then
    warn "Not bound permanently (zone is lost on 'firewall-cmd --reload'): ${perm_missing[*]}"
    if confirm "Bind them to zone 'libvirt' permanently?" y; then
      for br in "${perm_missing[@]}"; do
        sudo firewall-cmd --permanent --zone=libvirt --change-interface="$br" >/dev/null
      done
      ok "Permanently bound: ${perm_missing[*]}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
info "Storage"
# ---------------------------------------------------------------------------
sudo mkdir -p /var/lib/libvirt/images /var/lib/libvirt/boot
if ! v pool-info default &>/dev/null; then
  v pool-define-as default dir --target /var/lib/libvirt/images >/dev/null
  v pool-build default >/dev/null || true
fi
v pool-start default &>/dev/null || true
v pool-autostart default >/dev/null
ok "Storage pool 'default' -> /var/lib/libvirt/images"
ok "Put ISOs in /var/lib/libvirt/boot"

# ---------------------------------------------------------------------------
info "Network health checks"
# ---------------------------------------------------------------------------
if [[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]; then
  ok "IPv4 forwarding enabled"
else
  warn "net.ipv4.ip_forward = 0 - NAT networks cannot reach the internet"
fi

rules=$( { sudo nft list ruleset 2>/dev/null || true; sudo iptables -t nat -S 2>/dev/null || true; } )
mapfile -t nets < <(active_nets)
for n in "${nets[@]}"; do
  [[ $(net_mode "$n") == nat ]] || continue
  br=$(net_bridge "$n")
  cidr=$(ip -4 -o addr show dev "$br" 2>/dev/null | awk 'NR==1 {print $4}' || true)
  if [[ -z $cidr ]]; then warn "$n: bridge $br has no IPv4 address"; continue; fi
  subnet=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$cidr")
  if grep -Eiq "${subnet//./\\.}.*masquerade" <<<"$rules"; then
    ok "$n ($subnet): NAT rules present"
  else
    warn "$n ($subnet): no masquerade rule found - restart the network: virsh net-destroy $n && virsh net-start $n"
  fi
done

clashes=$(python3 - <<'PY' || true
import ipaddress, json, subprocess
out = subprocess.run(["ip", "-j", "-4", "route"], capture_output=True, text=True).stdout
lib, other = [], []
for r in json.loads(out or "[]"):
    dst, dev = r.get("dst"), r.get("dev", "")
    if not dst or dst == "default":
        continue
    try:
        net = ipaddress.ip_network(dst, strict=False)
    except ValueError:
        continue
    (lib if dev.startswith("virbr") else other).append((net, dev))
for i, (a, da) in enumerate(lib):
    for b, db in other + lib[i + 1:]:
        if a.overlaps(b):
            print(f"{a} ({da}) overlaps {b} ({db})")
PY
)
if [[ -n $clashes ]]; then
  while read -r line; do warn "Subnet clash: $line"; done <<<"$clashes"
else
  ok "No subnet clashes with host routes (VPN routes only show while connected)"
fi

if systemctl is-active --quiet docker 2>/dev/null; then
  warn "Docker is running - it can block forwarding on libvirt bridges (VMs without internet)."
elif systemctl is-enabled --quiet docker 2>/dev/null; then
  warn "Docker is enabled and will start on boot - it can block forwarding on libvirt bridges."
fi

# ---------------------------------------------------------------------------
info "Host validation"
# ---------------------------------------------------------------------------
sudo virt-host-validate qemu || warn "Some checks did not pass (IOMMU warnings are fine for normal VMs)."

# ---------------------------------------------------------------------------
info "Summary"
# ---------------------------------------------------------------------------
v net-list --all
echo
if (( NEED_RELOGIN )); then
  warn "LOG OUT AND BACK IN (or reboot) so the libvirt group membership takes effect."
fi
cat <<EOF

Next steps (as $TARGET_USER, no sudo):
  - Start virt-manager; the connection must be "QEMU/KVM" (not "User session").
  - Check:   virsh uri        -> $URI
             virsh net-list   -> default active
  - New VM:  network "Virtual network 'default': NAT"

Vagrant (use HashiCorp's Vagrant >= 2.4 + 'vagrant plugin install vagrant-libvirt'):
  config.vm.provider :libvirt do |lv|
    lv.qemu_use_session = false
    lv.uri = "$URI"
  end
EOF
