#!/bin/bash
#
# June 25 2017, Christian Hopps <chopps@gmail.com>
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

function create_cert_authority {
    certdir=$1
    shift

    mkdir -p $certdir

    if [[ ! -e $certdir/ca-key.pem ]]; then
        #
        # Generate a CA key
        #
        openssl genrsa -out $certdir/ca-key.pem 2048
        chmod 600 $certdir/ca-key.pem
    fi

    if [[ ! -e $certdir/ca.pem ]]; then
        openssl req -x509 -new -nodes -key $certdir/ca-key.pem -days 10000 -out $certdir/ca.pem -subj "/CN=hyperv-ca"
    fi
}

get_nbd_device () {
    # Make sure nbd is installed
    if ! lsmod | grep -q nbd; then
        ${SUDO} modprobe nbd max_part=16
    fi

    # Find the open nbd device
    declare device=
    for ((i=0; i<16; i++)); do
        device=/dev/nbd$i
        if ! ${SUDO} lsblk -n d 2> /dev/null; then
            break
        fi
    done
    if (( i == 16 )); then
        echo "nbd0 through nbd15 are all busy" >&2
        exit 1
    fi
    echo $device
}

create_image_and_partition () {
    declare device=$1; shift
    declare fmtarg=$1; shift
    declare imagefile=$1; shift
    declare imagesize=$1; shift

    $DOIT $SUDO qemu-img create $fmtarg $imagefile $imagesize
    $DOIT $SUDO qemu-nbd --connect=$device $imagefile
    $DOIT $SUDO parted -s -a optimal $device mklabel gpt
    $DOIT $SUDO parted -s -a optimal $device -- mkpart primary ext2 2 100%
    $DOIT $SUDO parted -s -a minimal $device -- mkpart primary 0 2
    $DOIT $SUDO parted -s -a optimal $device -- set 2 bios_grub on
    $DOIT $SUDO partprobe
    $DOIT $SUDO udevadm settle
    $DOIT $SUDO mkfs.ext4 ${device}p1
    $DOIT mkdir -p ${mountpoint}
    $DOIT $SUDO mount ${device}p1 ${mountpoint}
}

create_root_from_docker () {
    declare dockimg=$1; shift
    declare mountpoint=$1; shift

    declare TAR

    TAR=$(which bsdtar 2> /dev/null) || TAR=tar
    if [[ -z $TAR ]]; then
        TAR=tar
    fi

    echo "Running docker create for $dockimg"
    $DOIT declare P=$(docker create $dockimg)
    if ! $DOIT docker export $P | $DOIT ${SUDO} ${TAR} -xC ${mountpoint} -f -; then
        status=$?
        $DOIT docker rm $P
        return $status
    fi
    $DOIT docker rm $P

    # I believe we mount devtmpfs over dev so not sure we need this
    $DOIT bash -c "(cd ${mountpoint}/dev && ${SUDO} rm -f console && ${SUDO} mknod -m 600 console c 5 1)"
    for i in 0 1 2 3 4 5 6 7 8 9; do
        declare dev=$i
        $DOIT bash -c "(cd ${mountpoint}/dev && ${SUDO} rm -f tty$i && \
         ${SUDO} mknod -m 660 ttyS$i c 4 $dev && \
         ${SUDO} chown root:tty ttyS$i)"
    done
    for i in 0 1 2 3; do
        declare dev=$(($i + 64))
        $DOIT bash -c "(cd ${mountpoint}/dev && ${SUDO} rm -f ttyS$i && \
         ${SUDO} mknod -m 660 ttyS$i c 4 $dev && \
         ${SUDO} chown root:20 ttyS$i)"
    done
}

make_disk_bootable () {
    declare mountpoint=$1; shift
    declare device=$1; shift

    # # Which of these do we need for grub?
    # # $DOIT ${SUDO} mkdir -p ${mountpoint}/dev
    # $DOIT ${SUDO} mount --bind /dev ${mountpoint}/dev
    # # $DOIT ${SUDO} mkdir -p ${mountpoint}/proc
    # $DOIT ${SUDO} mount --bind /proc ${mountpoint}/proc
    # # $DOIT ${SUDO} mkdir -p ${mountpoint}/sys
    # $DOIT ${SUDO} mount --bind /sys ${mountpoint}/sys

    $DOIT ${SUDO} rm -f ${mountpoint}/etc/machine-id
    $DOIT ${SUDO} systemd-machine-id-setup --root=${mountpoint}

    $DOIT ${SUDO} mkdir -p ${mountpoint}/boot/grub
    $DOIT ${SUDO} bash -c "printf \"(hd0) $device\n\" > ${mountpoint}/boot/grub/device.map"
    $DOIT ${SUDO} grub-install --target=i386-pc --boot-directory=${mountpoint}/boot '(hd0)'

    $DOIT declare KERNEL=$(cd ${mountpoint}/boot && ls vmlinuz*)
    $DOIT declare INITRD=$(cd ${mountpoint}/boot && ls initrd*)

    declare rootuuid=$($DOIT $SUDO blkid -s UUID -o value ${device}p1)

    declare tmpf=/tmp/grub.$$
    $DOIT cat <<EOF > $tmpf
set timeout=2
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial
terminal_output serial
menuentry "Start Hypervisor" {
    insmod part_gpt
    insmod ext2
    set root=(hd0,gpt1)
    search --no-floppy --fs-uuid --set ${rootuuid}
    linux /boot/$KERNEL root=UUID=${rootuuid} console=ttyS0,115200n8 console=tty0 kvm-intel.nested=1
    initrd /boot/$INITRD
}
EOF
    $DOIT $SUDO mv $tmpf ${mountpoint}/boot/grub/grub.cfg
}

create_swap_file () {
    declare mountpoint=$1; shift
    declare swapm=$1; shift
    $DOIT ${SUDO} dd if=/dev/zero of=${mountpoint}/swapfile bs=1M count=$swapm
    $DOIT ${SUDO} chmod 600 ${mountpoint}/swapfile
    $DOIT ${SUDO} mkswap ${mountpoint}/swapfile
}

create_fstab () {
    declare mountpoint=$1; shift
    declare device=$1; shift

    declare rootuuid=$($DOIT $SUDO blkid -s UUID -o value ${device}p1)

    # Create fstab
    declare tmpf=/tmp/fstab.$$
    $DOIT cat <<EOF > $tmpf
tmpfs  /dev/shm tmpfs  defaults         0 0
devpts /dev/pts devpts gid=5,mode=620   0 0
sysfs  /sys     sysfs  defaults         0 0
proc   /proc    proc   defaults         0 0
UUID=$rootuuid /   ext4   rw,defaults,noatime 0 1
EOF
    if [[ -e ${mountpoint}/swapfile ]]; then
        echo "/swapfile none  swap   sw               0 0" >> $tmpf
    fi
    $DOIT ${SUDO} mv $tmpf ${mountpoint}/etc/fstab
}

init_hosts_resolv () {
    declare hosts_file=$1

    # Create symlink to resolved resolv.conf
    $DOIT ${SUDO} rm -f ${mountpoint}/etc/resolv.conf
    $DOIT ${SUDO} ln -fs ../run/systemd/resolve/resolv.conf ${mountpoint}/etc/resolv.conf

    # Docker also overlays the hosts file
    $DOIT ${SUDO} bash -c "printf \"127.0.0.1 localhost.localdomain localhost\n::1 localhost.localdomain localhost\n\" > ${mountpoint}/etc/hosts"

    if [[ -n $hosts_file ]]; then
        ${SUDO} bash -c "cat $hosts_file >> ${mountpoint}/etc/hosts"
    fi
}
