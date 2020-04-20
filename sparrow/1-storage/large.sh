#!/bin/bash
# 2020.3 by wufengguang
#
# Example fs/storage configuration.
# The smaller setup can be standalone partitions for /var/lib/docker and /srv 
# TODO: images, nfs rootfs, results, git mirror, repo mirror, ES db, redis db

# best SSD: small files; r/w; important data
pvcreate /dev/sdb
pvcreate /dev/sdc
vgcreate vg-db /dev/sdb /dev/sdc
lvcreate --type raid1 --size 100G -n lv-c vg-db
lvcreate --type raid1 --size 300G -n lv-es vg-db
lvcreate --type raid1 --size 100G -n lv-redis vg-db
lvcreate --type raid1 --size 100G -n lv-etcd vg-db
mkfs.ext4 /dev/vg-db/lv-c
mkfs.ext4 /dev/vg-db/lv-es
mkfs.ext4 /dev/vg-db/lv-redis
mkfs.ext4 /dev/vg-db/lv-etcd

# fast SSD: read most; rootfs
pvcreate /dev/sdd
vgcreate vg-os /dev/sdd
lvcreate --size 300G -n lv-os vg-os
lvcreate --size 300G -n lv-docker vg-os
mkfs.ext4 /dev/vg-os/lv-os
mkfs.ext4 /dev/vg-os/lv-docker

# large HDD: read most; large files
pvcreate /dev/sde
pvcreate /dev/sdf
vgcreate vg-image /dev/sde /dev/sdf
lvcreate --type raid1 --size 300G -n lv-initrd vg-image
mkfs.ext4 /dev/vg-image/lv-initrd

# large HDD: package repos; data not important
pvcreate /dev/sdg
vgcreate vg-cdn /dev/sdg
lvcreate --size 300G -n lv-openeuler vg-cdn
mkfs.ext4 /dev/vg-cdn/lv-openeuler

# large HDD: archive
pvcreate /dev/sdh
vgcreate vg-archive /dev/sdh
lvcreate --size 300G -n lv-backup vg-archive
mkfs.ext4 /dev/vg-archive/lv-backup

# fast SSD: crystal project files
pvcreate /dev/sdi
pvcreate /dev/sdj
vgcreate vg-crystal /dev/sdi /dev/sdj
lvcreate --type raid1 --size 100G -n lv-crystal vg-crystal
mkfs.ext4 /dev/vg-crystal/lv-crystal

# # large HDD: write most
# pvcreate /dev/sdi
# pvcreate /dev/sdj
# vgcreate vg-result /dev/sdi /dev/sdj
# lvcreate --type raid1 --size 100G -n lv-result vg-result
# mkfs.ext4 /dev/vg-result/lv-result

# fast SSD: git mirror
pvcreate /dev/sdk
vgcreate vg-git /dev/sdg
lvcreate --size 300G -n lv-git vg-git
mkfs.ext4 /dev/vg-git/lv-git

# large HDD: write most
pvcreate /dev/sdl
vgcreate vg-result /dev/sdl
lvcreate --size 300G -n lv-result vg-result
mkfs.ext4 /dev/vg-result/lv-result

cat >> /etc/fstab <<EOF
/dev/vg-db/lv-c                     /c               ext4  defaults        0       0
/dev/vg-db/lv-redis       	    /srv/redis       ext4  defaults        0       0
/dev/vg-db/lv-etcd       	    /srv/etcd        ext4  defaults        0       0
/dev/vg-db/lv-es         	    /srv/es          ext4  defaults        0       0
/dev/vg-os/lv-os                    /srv/os    	     ext4  defaults        0       0
/dev/vg-result/lv-result            /srv/result      ext4  defaults        0       0
/dev/vg-image/lv-initrd 	    /srv/initrd	     ext4  defaults        0       0
/dev/vg-git/lv-git                  /srv/git         ext4  defaults        0       0
/dev/vg-crystal/lv-crystal          /cci             ext4  defaults        0       0
/dev/vg-archive/lv-backup           /backup          ext4  defaults        0       0
/dev/vg-os/lv-docker                /var/lib/docker  ext4  defaults        0       0
EOF


mkdir /srv/redis
mkdir /srv/etcd
mkdir /srv/es
mkdir /srv/os
mkdir /srv/result
mkdir /srv/initrd
mkdir /srv/git
mount /srv/redis
mount /srv/etcd
mount /srv/es
mount /srv/os
mount /srv/result
mount /srv/initrd
mount /srv/git
mkdir /cci
mount /cci
mkdir /backup
mount /backup
mkdir /var/lib/docker
mount /var/lib/docker
mkdir /c
mount /c
