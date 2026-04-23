sudo apt update && sudo apt install -y \
build-essential \
clang \
llvm \
lld \
gcc \
g++ \
make \
bc \
bison \
flex \
libssl-dev \
libelf-dev \
libncurses-dev \
libudev-dev \
libpci-dev \
libiberty-dev \
pahole \
cpio \
kmod \
liblz4-tool \
zstd \
xz-utils \
fakeroot \
dwarves \
rsync \
git \
pkg-config \
python3 \
python3-pip \
wget \
curl \
vim \
nano \
autoconf \
automake 
git clone https://github.com/Z-LFS/Z-LFS.git
cd Z-LFS/linux-5.17.4

make mrproper
make defconfig

./scripts/config --enable CONFIG_VIRTIO
./scripts/config --enable CONFIG_VIRTIO_PCI
./scripts/config --enable CONFIG_VIRTIO_BLK
./scripts/config --enable CONFIG_VIRTIO_RING

./scripts/config --enable CONFIG_BLK_DEV_INITRD
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT

./scripts/config --enable CONFIG_EXT4_FS
./scripts/config --enable CONFIG_BLK_DEV_DM
./scripts/config --enable CONFIG_DM_CRYPT
./scripts/config --enable CONFIG_MD

./scripts/config --enable CONFIG_BLK_DEV_ZONED
./scripts/config --enable CONFIG_NVME_CORE
./scripts/config --enable CONFIG_BLK_DEV_NVME

./scripts/config --module CONFIG_F2FS_FS

make olddefconfig

make CC=clang HOSTCC=clang -j"$(nproc)"
sudo make CC=clang HOSTCC=clang modules_install
sudo make CC=clang HOSTCC=clang install
sudo update-grub
