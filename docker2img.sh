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

DOIT=

source "${BASH_SOURCE%/*}/util.sh"

cleanup () {
    :
}

trap cleanup EXIT


# -------------
# CLI Arguments
# -------------

usage () {
    echo "usage: $0 [-c] [ -H hostsfile ] [ -k keysdir ] imagedir dockertag" >&2
    exit 1
}

hosts_file=
create_certs=
keys_dir=.
while getopts ":cH:k:" opt; do
    case "${opt}" in
        (c)
            create_certs=1
            ;;
        (H)
            hosts_file=$OPTARG
            ;;
        (k)
            keys_dir=$OPTARG
            ;;
        (*)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

imagedir=$1; shift || usage
dockimg=$1; shift || usage

if [[ -z $imagedir || -z $dockimg ]]; then
    usage
fi

cname=temp.$$

# Get the image name
iname=${dockimg##*/}
iname=${iname%%:*}

initrd=$iname-initrd.img
kernel=$iname-linux

SUDO=
[[ $(whoami) == root ]] || SUDO=sudo

mountpoint=/tmp/mount-$iname.$$
${SUDO} rm -rf ${mountpoint}
mkdir -p ${mountpoint}

# -------------------------------------------------
# Create docker image and export to tmp file system
# -------------------------------------------------

create_root_from_docker $dockimg $mountpoint

# Copy the kernel to imagedir
${SUDO} chown -R $(whoami) $imagedir
${SUDO} cp -p ${mountpoint}/boot/vmlinuz* $imagedir/$kernel
${SUDO} chown -R $(whoami) $imagedir
${SUDO} chmod 644 $imagedir/$kernel

init_hosts_resolv $hosts_file

# --------------
# Key Management
# --------------

# Setup some ssh.
${SUDO} mkdir -p ${mountpoint}/root/.ssh
${SUDO} chmod 700 ${mountpoint}/root/.ssh
${SUDO} ssh-keygen -P "" -t rsa -f ${mountpoint}/root/.ssh/id_rsa
${SUDO} bash -c "cat ${mountpoint}/root/.ssh/id_rsa.pub  >> ${mountpoint}/root/.ssh/authorized_keys"

# Add root key to extra users authorized keys
for u in chopps tsrun; do
    ${SUDO} mkdir -p ${mountpoint}/home/$u/.ssh
    ${SUDO} bash -c "cat ${mountpoint}/root/.ssh/id_rsa.pub >> ${mountpoint}/home/$u/.ssh/authorized_keys"
    # # Need to use the correct numerical uid here
    theuid=$(grep $u ${mountpoint}/etc/passwd | cut -f3 -d: )
    ${SUDO} chown -R $theuid ${mountpoint}/home/$u
done

keys_dir=$keys_dir/$iname-keys

# Save copy of the keys locally
${SUDO} chown $(whoami) $keys_dir
${SUDO} chmod 700 $keys_dir
# Save a copy of the keys
${SUDO} cp ${mountpoint}/root/.ssh/id_rsa $keys_dir

# Save a copy of the host keys
if [[ -n $(ls -1 /etc/ssh/*.pub || true) ]]; then
    ${SUDO} mkdir -p $keys_dir/hostkeys
    ${SUDO} cp ${mountpoint}/etc/ssh/*.pub $keys_dir/hostkeys
fi

# ----------------------------
# Create Certificate Authority
# ----------------------------
if [[ $create_certs ]]; then
    echo "Creating Certificate Authority"
    create_cert_authority $keys_dir

    ${SUDO} mkdir -p ${mountpoint}/var/hyperv/certs
    ${SUDO} cp $keys_dir/ca-key.pem $keys_dir/ca.pem ${mountpoint}/var/hyperv/certs
    ${SUDO} chown -R root:root ${mountpoint}/var/hyperv/certs
fi

${SUDO} chown -R $(whoami) $keys_dir

echo "Building $initrd"
(cd ${mountpoint}; ${SUDO} find . | ${SUDO} cpio -o -H newc | gzip) > $imagedir/$initrd

${SUDO} rm -rf ${mountpoint}
