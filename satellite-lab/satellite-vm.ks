#version=RHEL9
# satellite-vm.ks — unattended RHEL 9 base for the Satellite server.
# Tokens __ROOTPW__ / __RHSM_*__ / __INSTALL_SOURCE__ are rendered by
# 01-provision-satellite-vm.sh.
text
eula --agreed
firstboot --disable
reboot
# Install source: __INSTALL_SOURCE__ is rendered to either nothing (DVD media
# install, the default) or a CDN line (boot.iso + network install from the Red
# Hat CDN, which registers via RHSM below before packages are pulled).
__INSTALL_SOURCE__
lang en_US.UTF-8
keyboard --vckeymap=us
timezone America/Denver --utc
rootpw __ROOTPW__ --plaintext

# NIC1: libvirt 'default' network (NAT to host + upstream; DNS via host dnsmasq at .122.1)
network --device=52:54:00:5a:7e:01 --bootproto=static --ip=192.168.122.20 --netmask=255.255.255.0 --gateway=192.168.122.1 --nameserver=192.168.122.1 --hostname=satellite.demo.lab --activate
# NIC2: satlab provisioning segment (Satellite serves DHCP/DNS/TFTP here; no default route)
network --device=52:54:00:5a:7e:02 --bootproto=static --ip=192.168.150.10 --netmask=255.255.255.0 --nodefroute --activate

# --- Disk layout: minimal 40 GB OS disk; Pulp content lives on the host via NFS ---
# /boot 1G | / 32G | swap 4G | ~3G slack. /var/lib/pulp is mounted from the host
# NFS export (see 00b-host-nfs-storage.sh) in %post so the VM disk stays small.
bootloader --location=mbr --boot-drive=vda
zerombr
clearpart --all --initlabel --drives=vda
part /boot --fstype=xfs --size=1024 --asprimary
part pv.01 --fstype=lvmpv --size=1 --grow
volgroup vg_sat pv.01
logvol /              --vgname=vg_sat --name=lv_root  --size=32768 --fstype=xfs
logvol swap           --vgname=vg_sat --name=lv_swap  --size=4096

%packages
@core
chrony
firewalld
nfs-utils
vim-enhanced
tmux
bash-completion
sos
tar
%end

%addon com_redhat_kdump --disable
%end

%post --log=/root/ks-post.log
# Install the host's SSH public key for root so the orchestrator can SSH in
# (RHEL 9 sshd defaults to PermitRootLogin prohibit-password, i.e. key-only).
# __HOST_SSH_PUBKEY__ is rendered by 01-provision-satellite-vm.sh.
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "__HOST_SSH_PUBKEY__" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
restorecon -R /root/.ssh 2>/dev/null || true
# Register (activation key preferred, username/password fallback)
if [ -n "__RHSM_AK__" ]; then
  subscription-manager register --org="__RHSM_ORG__" --activationkey="__RHSM_AK__"
else
  subscription-manager register --username="__RHSM_USER__" --password="__RHSM_PASS__" --auto-attach
fi

# Attach only what Satellite 6.17 on RHEL 9 needs (adjust SAT_VER as required)
subscription-manager repos --disable='*'
subscription-manager repos \
  --enable=rhel-9-for-x86_64-baseos-rpms \
  --enable=rhel-9-for-x86_64-appstream-rpms \
  --enable=satellite-6.17-for-rhel-9-x86_64-rpms \
  --enable=satellite-maintenance-6.17-for-rhel-9-x86_64-rpms

# FQDN must resolve locally for the installer
echo "192.168.150.10 satellite.demo.lab satellite" >> /etc/hosts

# Mount /var/lib/pulp from the host NFS export (keeps the VM OS disk small).
# The host is reachable at the default-net gateway. NFSv4 does not need
# rpc.mountd, so attempt the mount directly rather than relying on showmount.
# The mount is added to fstab with _netdev so it mounts after networking.
HOST_GW=192.168.122.1
NFS_EXPORT=/var/lib/satlab/pulp
mkdir -p /var/lib/pulp
mounted=0
for i in $(seq 1 30); do
  if mount -t nfs4 -o rw,sync,hard,intr "$HOST_GW:$NFS_EXPORT" /var/lib/pulp 2>/dev/null; then
    mounted=1
    break
  fi
  sleep 2
done
if [ "$mounted" = 1 ]; then
  grep -q "$NFS_EXPORT" /etc/fstab || \
    echo "$HOST_GW:$NFS_EXPORT /var/lib/pulp nfs4 rw,sync,hard,intr,_netdev 0 0" >> /etc/fstab
else
  echo "WARN: host NFS export $NFS_EXPORT not reachable; /var/lib/pulp is local" >> /root/ks-post.log
fi
%end
