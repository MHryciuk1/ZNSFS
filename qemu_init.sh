rm -rf zns.img meta.img vm.qcow2
qemu-img create -f qcow2 vm.qcow2 40G
truncate -s 64G zns.img
truncate -s 512M meta.img
rm -rf tmp
mkdir -p tmp/iso
sudo mount -o loop ubuntu-22.04.5-live-server-amd64.iso tmp/iso
cp tmp/iso/casper/vmlinuz tmp/vmlinuz
cp tmp/iso/casper/initrd tmp/initrd.img
sudo umount tmp/iso
qemu-system-x86_64 \
  -enable-kvm \
  -m 8G -smp 4 -cpu host \
  -kernel tmp/vmlinuz \
  -initrd tmp/initrd.img \
  -append "root=/dev/loop0 console=ttyS0,115200n8 earlyprintk=serial" \
  -drive file=vm.qcow2,if=virtio,format=qcow2 \
  -drive file=ubuntu-22.04.5-live-server-amd64.iso,media=cdrom,readonly=on \
  -device nvme,id=nvme0,serial=deadbeef \
  -drive file=zns.img,if=none,id=zns0,format=raw \
  -device nvme-ns,drive=zns0,bus=nvme0,nsid=1,zoned=true,zoned.zone_size=64M,zoned.zone_capacity=64M \
  -drive file=meta.img,if=virtio,format=raw \
  -net nic -net user \
  -nographic \
  -serial mon:stdio
