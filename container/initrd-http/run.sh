#!/bin/bash
. ../lab.sh
cmd=(
	docker run
	-it
#	--name initrd-http
	-p ${INITRD_HTTP_PORT:-8800}:80
	-v /srv/initrd:/usr/share/nginx/html/initrd:ro
	-d
	initrd-http
)

"${cmd[@]}"
