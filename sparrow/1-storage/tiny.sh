#!/bin/bash

dirs=(
	/srv/es
	/srv/git
	/srv/initrd
	/srv/initrd/pkg
	/srv/initrd/deps
	/srv/os
	/srv/redis
	/srv/result
	/srv/scheduler
)

mkdir -p "${dirs[@]}"
