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

create_root_from_docker () {
    dest=$1
    echo "Running docker create for $dockertag"
    P=$(docker create --name=$iname $dockertag)
    $DOIT docker export $P | $DOIT ${SUDO} tar -xC /tmp/$iname -f -
    $DOIT docker rm $P

    # # Copy the kernel
    # ${SUDO} bash -c "cat < /tmp/$iname/boot/vmlinuz*" | cat > $imagedir/$kernel

    # I believe we mount devtmpfs over dev so not sure we need this
    $DOIT bash -c "(cd ${dest}/dev && ${SUDO} rm -f console && ${SUDO} mknod -m 600 console c 5 1)"
    for i in 0 1 2 3 4 5 6 7 8 9; do
        dev=$i
        $DOIT bash -c "(cd ${dest}/dev && ${SUDO} rm -f tty$i && \
                            ${SUDO} mknod -m 660 tty$i c 4 $dev && \
                            ${SUDO} chown root:tty tty$i)"
    done
    for i in 0 1 2 3; do
        dev=$(($i + 64))
        $DOIT bash -c "(cd ${dest}/dev && ${SUDO} rm -f ttyS$i && \
                            ${SUDO} mknod -m 660 ttyS$i c 4 $dev && \
                            ${SUDO} chown root:20 ttyS$i)"
    done
}

cleanup () {
    if [ -n "$P" ]; then
        docker rm $P || true;
    fi
}

trap cleanup EXIT


# -------------
# CLI Arguments
# -------------

usage () {
    echo "usage: $0 [-c] [ -H hostsfile ] imagedir dockertag" >&2
    exit 1
}

hosts_file=
create_certs=
while getopts ":cH:" opt; do
    case "${opt}" in
        (c)
            create_certs=1
            ;;
        (H)
            hosts_file=$OPTARG
            ;;
        (*)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

imagedir=$1; shift || usage
dockertag=$1; shift || usage

if [[ -z $imagedir || -z $dockertag ]]; then
    usage
fi

cname=temp.$$

# Get the image name
iname=${dockertag##*/}
iname=${iname%%:*}

initrd=$iname-initrd.img
kernel=$iname-linux

SUDO=
[[ $(whoami) == root ]] || SUDO=sudo

${SUDO} rm -rf /tmp/$iname
mkdir -p /tmp/$iname

# -------------------------------------------------
# Create docker image and export to tmp file system
# -------------------------------------------------

create_root_from_docker

# Docker will always have an empty resolv.conf file create a new one.
# This should be handled by systemd-resolved and the network files.
# ${SUDO} bash -c "printf \"nameserver 8.8.8.8\nnameserver 2001:4860:4860::8888\n\" > /tmp/$iname/etc/resolv.conf"

# Docker also appears to overlay the hosts file
${SUDO} bash -c "printf \"127.0.0.1 localhost.localdomain localhost\n::1 localhost.localdomain localhost\n\" > /tmp/$iname/etc/hosts"
# ${SUDO} bash -c "printf \"::1 localhost.localdomain localhost\n\" > /tmp/$iname/etc/hosts"
if [[ -n $hosts_file ]]; then
    ${SUDO} bash -c "cat $hosts_file >> /tmp/$iname/etc/hosts"
fi


# Setup some ssh.
${SUDO} mkdir -p /tmp/$iname/root/.ssh
${SUDO} chmod 700 /tmp/$iname/root/.ssh
${SUDO} ssh-keygen -P "" -t rsa -f /tmp/$iname/root/.ssh/id_rsa
${SUDO} cp /tmp/$iname/root/.ssh/{id_rsa.pub,authorized_keys}

# Copy root key to extra users
for u in chopps tsrun; do
    ${SUDO} cp -pr /tmp/$iname/root/.ssh /tmp/$iname/home/$u
    # # Need to use the correct numerical uid here
    theuid=$(grep $u /tmp/$iname/etc/passwd | cut -f3 -d: )
    ${SUDO} chown -R $theuid /tmp/$iname/home/$u
done

# Save copy of the keys locally
${SUDO} mkdir -p $iname-keys/hostkeys
${SUDO} chown $(whoami) $iname-keys
${SUDO} chmod 700 $iname-keys
# Save a copy of the keys
${SUDO} cp /tmp/$iname/root/.ssh/id_rsa $iname-keys
${SUDO} cp /tmp/$iname/etc/ssh/*.pub $iname-keys/hostkeys

# ----------------------------
# Create Certificate Authority
# ----------------------------
if [[ $create_certs ]]; then
    echo "Creating Certificate Authority"
    create_cert_authority $iname-keys

    ${SUDO} mkdir -p /tmp/$iname/var/hyperv/certs
    ${SUDO} cp $iname-keys/ca-key.pem $iname-keys/ca.pem /tmp/$iname/var/hyperv/certs
    ${SUDO} chown -R root:root /tmp/$iname/var/hyperv/certs
fi

${SUDO} chown -R $(whoami) $iname-keys

echo "Building $initrd"
(cd /tmp/$iname; ${SUDO} find . | ${SUDO} cpio -o -H newc | gzip) > $imagedir/$initrd

${SUDO} rm -rf /tmp/$iname
