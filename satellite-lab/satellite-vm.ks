#version=RHEL9
# satellite-vm.ks — unattended RHEL 9 base for the Satellite server.
# Tokens __ROOTPW__ / __RHSM_*__ are rendered by 01-provision-satellite-vm.sh.
text
eula --agreed
firstboot --disable
reboot
lang en_US.UTF-8
keyboard --vckeymap=us
timezone America/Denver --utc
rootpw __ROOTPW__ --plaintext

# NIC1: libvirt 'default' network (NAT to host + upstream; DNS via host dnsmasq at .122.1)
network --device=52:54:00:5a:7e:01 --bootproto=static --ip=192.168.122.20 --netmask=255.255.255.0 --gateway=192.168.122.1 --nameserver=192.168.122.1 --hostname=satellite.demo.lab --activate
# NIC2: satlab provisioning segment (Satellite serves DHCP/DNS/TFTP here; no default route)
network --device=52:54:00:5a:7e:02 --bootproto=static --ip=192.168.150.10 --netmask=255.255.255.0 --nodefroute --activate

# --- Disk layout: 150 GB virtio disk, LVM with dedicated Pulp/log/pgsql volumes ---
# /boot 1G | / 40G | /var/lib/pulp 70G | /var/log 15G | /var/lib/pgsql 12G | swap 4G | ~7G slack
bootloader --location=mbr --boot-drive=vda
zerombr
clearpart --all --initlabel --drives=vda
part /boot --fstype=xfs --size=1024 --asprimary
part pv.01 --fstype=lvmpv --size=1 --grow
volgroup vg_sat pv.01
logvol /              --vgname=vg_sat --name=lv_root  --size=40960 --fstype=xfs
logvol /var/lib/pulp  --vgname=vg_sat --name=lv_pulp  --size=71680 --fstype=xfs
logvol /var/log       --vgname=vg_sat --name=lv_log   --size=15360 --fstype=xfs
logvol /var/lib/pgsql --vgname=vg_sat --name=lv_pgsql --size=12288 --fstype=xfs
logvol swap           --vgname=vg_sat --name=lv_swap  --size=4096

%packages
@core
chrony
firewalld
vim-enhanced
tmux
bash-completion
sos
tar
%end

%addon com_redhat_kdump --disable
%end

%post --log=/root/ks-post.log
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
%end
