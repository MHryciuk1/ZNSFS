# ZNSFS
qemu setup on arch
```
sudo pacman -S qemu-full
wget https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
qemu-img create -f qcow2 vm.qcow2 40G
truncate -s 16G zns.img
