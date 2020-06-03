#!/bin/bash

cd /c || exit

git clone -b custom-config  https://gitee.com/wu_fengguang/ipxe.git

cd ipxe || exit

make ARCH=arm64 bin-arm64-efi/ipxe.efi
make ARCH=arm64 bin-arm64-efi/snponly.efi
make ARCH=arm64 bin-arm64-efi/snp.efi
make CONFIG=rpi bin-arm64-efi/rpi.efi

mkdir -p                  /tftpboot/ipxe/bin-arm64-efi/
cp -a bin-arm64-efi/*.efi /tftpboot/ipxe/bin-arm64-efi/
