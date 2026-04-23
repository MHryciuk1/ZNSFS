# ZNSFS
qemu setup on arch
```
sudo pacman -S qemu-full
wget https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso
qemu-img create -f qcow2 vm.qcow2 40G
truncate -s 16G zns.img
truncate -s 512M meta.img
```
qemu setup command
```
qemu-system-x86_64 \
  -enable-kvm \
  -m 8G -smp 4 -cpu host \
  -kernel /tmp/vmlinuz \
  -initrd /tmp/initrd.img \
  -append "root=/dev/loop0 console=ttyS0,115200n8 earlyprintk=serial" \
  -drive file=vm.qcow2,if=virtio,format=qcow2 \
  -drive file=ubuntu-24.04.4-live-server-amd64.iso,media=cdrom,readonly=on \
  -device nvme,id=nvme0,serial=deadbeef \
  -drive file=zns.img,if=none,id=zns0,format=raw \
  -device nvme-ns,drive=zns0,bus=nvme0,nsid=1,zoned=true,zoned.zone_size=64M,zoned.zone_capacity=64M \
  -drive file=meta.img,if=virtio,format=raw \
  -net nic -net user \
  -nographic \
  -serial mon:stdio
```


# after initial setup use this to run qemu 
```
qemu-system-x86_64 \
  -enable-kvm \
  -m 8G \
  -smp 4 \
  -cpu host \
  -drive file=vm.qcow2,if=virtio,format=qcow2 \
  -device nvme,id=nvme0,serial=deadbeef \
  -drive file=zns.img,if=none,id=zns0,format=raw \
  -device nvme-ns,drive=zns0,bus=nvme0,nsid=1,zoned=true,zoned.zone_size=64M,zoned.zone_capacity=64M \
  -drive file=meta.img,if=virtio,format=raw \
  -net user,hostfwd=tcp::2222-:22 \
  -net nic \
  -nographic
```
you can ssh into it if you want
```
ssh -p 2222 user@localhost
```
# F2FS setup
f2fs requires a small conventional drive for the metadata
inside vm
use lsblk to sanity check
```
mkfs.f2fs -f -m -c /dev/vdb /dev/nvme0n1
mount -t f2fs /dev/vdb /mnt/f2fs/
```
# z-lfs
```
qemu-system-x86_64 \
  -enable-kvm \
  -m 8G \
  -smp 4 \
  -cpu host \
  -kernel vmlinuz-5.17.4 \
  -initrd initrd.img-5.17.4 \
  -append "root=/dev/mapper/ubuntu--vg-ubuntu--lv console=ttyS0 loglevel=7" \
  -drive file=vm.qcow2,if=virtio,format=qcow2 \
  -device nvme,id=nvme0,serial=deadbeef \
  -drive file=zns.img,if=none,id=zns0,format=raw \
  -device nvme-ns,drive=zns0,bus=nvme0,nsid=1,zoned=true,zoned.zone_size=64M,zoned.zone_capacity=64M \
  -drive file=meta.img,if=virtio,format=raw \
  -net user,hostfwd=tcp::2222-:22 \
  -net nic \
  -nographic
```
# other
you may need to extract kernel
```
mkdir -p /tmp/iso
sudo mount -o loop ubuntu-24.04.4-live-server-amd64.iso /tmp/iso
cp /tmp/iso/casper/vmlinuz /tmp/vmlinuz
cp /tmp/iso/casper/initrd /tmp/initrd.img
sudo umount /tmp/iso
```

