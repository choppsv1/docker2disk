#!/bin/bash
#
# June 10 2017, Christian Hopps <chopps@gmail.com>
#
# Copyright (c) 2017, Deutsche Telekom AG.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -ex

cleanup () {
    if [[ "$P" ]]; then
        $DOIT docker rm $P || true
    fi
    if [[ ${mountpoint} ]]; then
        $DOIT ${SUDO} umount ${mountpoint}/proc || true
        $DOIT ${SUDO} umount ${mountpoint}/sys || true
        $DIIT ${SUDO} umount ${mountpoint}/dev || true
        $DOIT ${SUDO} umount ${mountpoint} || true
        $DOIT ${SUDO} rmdir ${mountpoint} || true
    fi
    if [[ $device ]]; then
        $DOIT ${SUDO} qemu-nbd --disconnect $device
    fi
}
trap cleanup EXIT

get_nbd_device () {
    # Make sure nbd is installed
    if ! lsmod | grep -q nbd; then
        ${SUDO} modprobe nbd max_part=16
    fi

    # Find the open nbd device
    device=
    for ((i=0; i<16; i++)); do
        device=/dev/nbd$i
        if ! ${SUDO} lsblk -n d 2> /dev/null; then
            break
        fi
    done
    if (( i == 16 )); then
        echo "nbd0 through nbd15 are all busy"
        exit 1
    fi
}

# -------------
# CLI Arguments
# -------------

usage () {
    echo "usage: $0 [-fn] [ -F disk-foramt ]  dockerimage diskimage size" >&2
    exit 1
}

force=
SWAPM=2048
fmtarg="-f qcow2"
while getopts ":fF:n" opt; do
    case "${opt}" in
        # (e)
        #     efi=1
        #     ;;
        (f)
            force=1
            ;;
        (F)
            fmtarg="-f $OPTARG"
            ;;
        (n)
            DOIT=echo
            ;;
        (*)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

dockimg=$1; shift || usage
imagefile=$1; shift || usage
imagesize=$1; shift || usage

if [[ -z $dockimg || -z $imagefile || -z $imagesize ]]; then
    usage
fi

# ---------
# Variables
# ---------

[[ $(whoami) == root ]] || SUDO=sudo

mountpoint=/tmp/docker2img.mp.$$

# Get the image name
iname=${dockimg##*/}
iname=${iname%%:*}

# XXX I don't think we need these
initrd=$iname-initrd.img
kernel=$iname-linux

# -----------------------------------------------------
# Create, connect, partition, format and mount our disk
# -----------------------------------------------------

if [[ -e $imagefile && ! $force ]]; then
    echo "$imagefile already exists, use -f to overwrite"
    exit 1
fi

get_nbd_device

$DOIT $SUDO qemu-img create $fmtarg $imagefile $imagesize
$DOIT $SUDO qemu-nbd --connect=$device $imagefile
$DOIT $SUDO parted -s -a optimal $device mklabel gpt
$DOIT $SUDO parted -s -a optimal $device -- mkpart primary ext2 2 100%
$DOIT $SUDO parted -s -a minimal $device -- mkpart primary 0 2
$DOIT $SUDO parted -s -a optimal $device -- set 2 bios_grub on
$DOIT $SUDO partprobe
$DOIT $SUDO udevadm settle
$DOIT $SUDO mkfs.ext4 ${device}p1
$DOIT declare ROOTUUID=$(${SUDO} blkid -s UUID -o value ${device}p1)
$DOIT mkdir -p ${mountpoint}
$DOIT $SUDO mount ${device}p1 ${mountpoint}

# ------------------------------------------
# Create docker image and export to our disk
# ------------------------------------------

echo "Running docker create for $dockimg"
$DOIT declare P=$(docker create --name=$iname $dockimg)
$DOIT docker export $P | $DOIT ${SUDO} tar -xC ${mountpoint} -f -

# I believe we mount devtmpfs over dev so not sure we need this
$DOIT bash -c "(cd ${mountpoint}/dev && ${SUDO} rm -f console && ${SUDO} mknod -m 600 console c 5 1)"
for i in 0 1 2 3 4 5 6 7 8 9; do
    dev=$i
    $DOIT bash -c "(cd ${mountpoint}/dev && ${SUDO} rm -f tty$i && \
         ${SUDO} mknod -m 660 ttyS$i c 4 $dev && \
         ${SUDO} chown root:tty ttyS$i)"
done
for i in 0 1 2 3; do
    dev=$(($i + 64))
    $DOIT bash -c "(cd ${mountpoint}/dev && ${SUDO} rm -f ttyS$i && \
         ${SUDO} mknod -m 660 ttyS$i c 4 $dev && \
         ${SUDO} chown root:20 ttyS$i)"
done

# ----------------
# Make it bootable
# ----------------

$DOIT ${SUDO} mkdir -p ${mountpoint}/boot/grub
# Which of these do we need for grub?
$DOIT ${SUDO} mount --bind /dev ${mountpoint}/dev
$DOIT ${SUDO} mount --bind /proc ${mountpoint}/proc
$DOIT ${SUDO} mount --bind /sys ${mountpoint}/sys

$DOIT ${SUDO} rm -f ${mountpoint}/etc/machine-id
$DOIT ${SUDO} systemd-machine-id-setup --root=${mountpoint}
$DOIT ${SUDO} bash -c "printf \"(hd0) $device\n\" > ${mountpoint}/boot/grub/device.map"
$DOIT ${SUDO} grub-install --target=i386-pc --boot-directory=${mountpoint}/boot '(hd0)'

$DOIT declare KERNEL=$(cd ${mountpoint}/boot && ls vmlinuz*)
$DOIT declare INITRD=$(cd ${mountpoint}/boot && ls initrd*)

tmpf=/tmp/grub.$$
$DOIT cat <<EOF > $tmpf
set timeout=2
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial
terminal_output serial
menuentry "Start Hypervisor" {
    insmod part_gpt
    insmod ext2
    set root=(hd0,gpt1)
    search --no-floppy --fs-uuid --set ${ROOTUUID}
    linux /boot/$KERNEL root=UUID=${ROOTUUID} console=ttyS0,115200n8 kvm-intel.nested=1
    initrd /boot/$INITRD
}
EOF
$DOIT $SUDO mv $tmpf ${mountpoint}/boot/grub/grub.cfg

# Create swap

$DOIT ${SUDO} dd if=/dev/zero of=${mountpoint}/swapfile bs=1M count=$SWAPM
$DOIT ${SUDO} chmod 600 ${mountpoint}/swapfile
$DOIT ${SUDO} mkswap ${mountpoint}/swapfile

# Create fstab
$DOIT cat <<EOF > $tmpf
tmpfs  /dev/shm tmpfs  defaults         0 0
devpts /dev/pts devpts gid=5,mode=620   0 0
sysfs  /sys     sysfs  defaults         0 0
proc   /proc    proc   defaults         0 0
UUID=$ROOTUUID /   ext4   rw,defaults,noatime 0 1
/swapfile none  swap   sw               0 0
EOF
$DOIT ${SUDO} mv $tmpf ${mountpoint}/etc/fstab

# Create symlink to resolved resolv.conf
$DOIT ${SUDO} rm -f ${mountpoint}/etc/resolv.conf
$DOIT ${SUDO} ln -fs ../run/systemd/resolve/resolv.conf ${mountpoint}/etc/resolv.conf

# Docker also overlays the hosts file
$DOIT ${SUDO} bash -c "printf \"127.0.0.1 localhost.localdomain localhost\n::1 localhost.localdomain localhost\n\" > ${mountpoint}/etc/hosts"

# umount ${mountpoint}/proc
# umount ${mountpoint}/sys