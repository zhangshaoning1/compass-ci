#!/bin/bash
# 2020.3 by wufengguang

ip link add br0 type bridge
ip addr add 192.168.177.1/24 dev br0
ip link set dev br0 up

brctl setfd br0 2

ip link add br0-nic type dummy
ip link set br0-nic master br0
ip link set br0-nic multicast on arp on

grep -qx "allow br0" /etc/qemu/bridge.conf ||
echo  "allow br0" >> /etc/qemu/bridge.conf
