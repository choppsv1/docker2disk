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

source "${BASH_SOURCE%/*}/util.sh"

cleanup () {
    exitcode=$?
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
    if (( $exitcode != 0 )); then
        ${SUDO} rm $imagefile
    elif [[ $imagefile ]]; then
        # change ownership to user
        ${SUDO} chown ${USER} $imagefile
    fi
}
trap cleanup EXIT

# -------------
# CLI Arguments
# -------------

usage () {
    echo "usage: $0 [-fn] [ -F disk-foramt ]  dockerimage diskimage size" >&2
    exit 1
}

force=
swapsize=2048
fmtarg="-f qcow2"
create_certs=
while getopts ":fF:ns:" opt; do
    case "${opt}" in
        (c)
            create_certs=1
            ;;
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
        (s)
            swapsize=$OPTARG
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

if [[ -e $imagefile && ! $force ]]; then
    echo "$imagefile already exists, use -f to overwrite"
    exit 1
fi

# ---------
# Variables
# ---------

[[ $(whoami) == root ]] || SUDO=sudo

mountpoint=/tmp/docker2img.mp.$$

# Get the image name
iname=${dockimg##*/}
iname=${iname%%:*}

device=$(get_nbd_device)
create_image_and_partition "$device" "$fmtarg" "$imagefile" "$imagesize" "$mountpoint"
create_root_from_docker $dockimg $mountpoint
if (( $swapsize > 0 )); then
    create_swap_file $mountpoint $swapsize
fi
make_disk_bootable $mountpoint $device
create_fstab $mountpoint $device
init_hosts_resolv
