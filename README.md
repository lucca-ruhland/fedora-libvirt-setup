# fedora-libvirt-setup

Idempotent setup of libvirt + QEMU/KVM + virt-manager on Fedora, so a normal
(non-root) user can manage VMs on `qemu:///system` via the `libvirt` group.

It never deletes VMs, disk images or networks, and asks before restarting a
network that has running VMs attached.

## Usage

Run as your normal user, **not** with sudo (the script calls sudo itself):

```sh
./setup-libvirt.sh                              # interactive
./setup-libvirt.sh --yes                        # answer "yes" to all questions
FIREWALL_BACKEND=nftables ./setup-libvirt.sh    # or iptables
```

If `FIREWALL_BACKEND` is unset, `/etc/libvirt/network.conf` is left as is.
`nftables` is recommended on Fedora.

If you were newly added to the `libvirt` group, log out and back in afterwards.

## What it does

- Checks for Fedora and CPU virtualization support (VT-x / AMD-V)
- Installs the virtualization packages, virt-manager and virt-install
- Switches from monolithic `libvirtd` to the modular daemons (asks first)
- Optionally sets the libvirt firewall backend
- Adds you to the `libvirt` group and sets `uri_default` in
  `~/.config/libvirt/libvirt.conf`
- Defines, starts and autostarts the `default` NAT network and storage pool
  (`/var/lib/libvirt/images`, ISOs in `/var/lib/libvirt/boot`)
- Puts libvirt bridges in the firewalld `libvirt` zone
- Checks IP forwarding, NAT rules, subnet clashes and whether Docker is running,
  then runs `virt-host-validate`

## Testing

Tested only on Fedora Linux 43, and not thoroughly. Read the script before
running it; it changes system configuration with sudo.

## License

GPLv3, see [LICENSE](LICENSE). Provided as is, without any warranty.
