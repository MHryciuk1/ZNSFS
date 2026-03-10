# ZNSFS
qemu setup on arch
```
sudo pacman -S qemu-full
wget https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso
qemu-img create -f qcow2 vm.qcow2 40G
truncate -s 16G zns.img

qemu-system-x86_64 \
  -enable-kvm \
  -m 8G \
  -smp 4 \
  -cpu host \
  -drive file=vm.qcow2,if=virtio,format=qcow2 \
  -cdrom ubuntu-24.04.4-live-server-amd64.iso \
  -device nvme,id=nvme0,serial=deadbeef \
  -drive file=zns.img,if=none,id=zns0,format=raw \
  -device nvme-ns,drive=zns0,bus=nvme0,nsid=1,zoned=true,zoned.zone_size=64M,zoned.zone_capacity=64M \
  -net nic \
  -net user \
  -nographic
