#!/bin/bash
#
# June 12 2017, Christian Hopps <chopps@gmail.com>
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

set -e

source "${BASH_SOURCE%/*}/util.sh"

cleanup () {
    if [[ "$P" ]]; then
        $DOIT docker rm $P || true
    fi
    if [[ -d ${mountpoint} ]]; then
        $DOIT ${SUDO} umount ${mountpoint} || true
        $DOIT ${SUDO} rmdir ${mountpoint}
    fi
    if [[ -e /dev/mapper/$basename-$basename ]]; then
        $DOIT ${SUDO} dmsetup remove $basename-$basename
    fi
    if [[ $device ]]; then
        $DOIT ${SUDO} qemu-nbd --disconnect $device
    fi
}
trap cleanup EXIT

# -------------
# CLI Arguments
# -------------

usage () {
    echo "usage: $0 [-fn] [ -F disk-foramt ] [ -N volname ] tarfile diskimage size" >&2
    exit 1
}

declare basename=
forceflag=
fmtarg="-f qcow2"
while getopts ":fF:n" opt; do
    case "${opt}" in
        (f)
            forceflag=-f
            ;;
        (F)
            fmtarg="-f $OPTARG"
            ;;
        (n)
            DOIT=echo
            ;;
        (N)
            basename=$OPTARG
            ;;
        (*)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

tarfile=$1; shift || usage
imagefile=$1; shift || usage
imagesize=$1; shift || usage

if [[ -z $basename ]]; then
    basename=${tarfile%%.tar*}
fi
declare mappath=/dev/mapper/$basename-$basename

if [[ -z $tarfile || -z $imagefile || -z $imagesize ]]; then
    usage
fi
imagesize=${imagesize^^}

if [[ -z "${imagesize%%*K}" ]]; then
    imagesize=$((${imagesize%%K} * 1024))
elif [[ -z "${imagesize%%*M}" ]]; then
    imagesize=$((${imagesize%%M} * 1024 * 1024))
elif [[ -z "${imagesize%%*G}" ]]; then
    imagesize=$((${imagesize%%G} * 1024 * 1024 * 1024))
fi

# ---------
# Variables
# ---------

[[ $(whoami) == root ]] || SUDO=sudo

mountpoint=/tmp/tar2disk.mp.$$

# -----------------------------------------------------
# Create, connect, partition, format and mount our disk
# -----------------------------------------------------

if [[ -e $imagefile && ! $forceflag ]]; then
    echo "$imagefile already exists, use -f to overwrite"
    exit 1
fi

device=$(get_nbd_device)

# Base this on the size given
EXTENTKSIZE=128
EXTENTSIZE=$(($EXTENTKSIZE * 1024))
declare extents=$(($imagesize / $EXTENTSIZE - 8))

$DOIT $SUDO qemu-img create $fmtarg $imagefile $imagesize
$DOIT $SUDO qemu-nbd $fmtarg --connect=$device $imagefile
$DOIT $SUDO pvcreate -y -ff $device
$DOIT $SUDO vgcreate --physicalextentsize ${EXTENTKSIZE}k $basename $device
$DOIT $SUDO lvcreate --extents=$extents --name $basename $basename $device
$DOIT $SUDO udevadm settle
$DOIT $SUDO mkfs.ext4 $mappath
$DOIT $SUDO mkdir -p ${mountpoint}
$DOIT $SUDO mount $mappath ${mountpoint}
$DOIT $SUDO udevadm settle

# --------------------------
# Extract tar to mountpoint
# --------------------------

if [[ -d $tarfile ]]; then
    $DOIT ${SUDO} bash -c "(tar -C $tarfile -cf - . | tar -xC ${mountpoint} -f -)"
else
    $DOIT ${SUDO} tar -xC ${mountpoint} -f $tarfile
fi
