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


ROUTE=$1
TIMEOUT="$2"
if [ -z "$TIMEOUT" ]; then
    TIMEOUT=30
fi

SLEEP=1

now () {
    date +%s
}

base=$(now)
until=$(($base + $TIMEOUT))

while true; do
    if  ip route | grep -q $ROUTE; then
        echo "$ROUTE is present in $(($(now) - $base))s"
        exit 0
    fi
    if [ $(now) -ge $until ]; then
        echo "$ROUTE is not present, giving up after $(($(now) - $base))s"
        exit 1
    fi
    echo "$ROUTE is not yet present in $(($(now) - $base))s retrying in ${SLEEP}s"
    sleep $SLEEP
done
