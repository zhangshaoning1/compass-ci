#!/bin/bash
# SPDX-License-Identifier: MulanPSL-2.0+
# - hostname

. $LKP_SRC/lib/yaml.sh
. $CCI_SRC/container/lab.sh

load_cci_defaults

: ${hostname:="vm-hi1620-1p1g-1"}
# unicast prefix: x2, x6, xA, xE
export mac=$(echo $hostname | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/0a-\1-\2-\3-\4-\5/')
echo hostname: $hostname
echo mac: $mac
echo $mac > mac
echo "arp -n | grep ${mac//-/:}" > ip.sh
chmod +x ip.sh

curl -X PUT "http://${SCHED_HOST:-172.17.0.1}:${SCHED_PORT:-3000}/set_host_mac?hostname=${hostname}&mac=${mac}"

trap 'curl -X PUT "http://${SCHED_HOST:-172.17.0.1}:${SCHED_PORT:-3000}/del_host_mac?mac=${mac}"' INT

(
	if [[ $hostname =~ ^(.*)-[0-9]+$ ]]; then
		tbox_group=${BASH_REMATCH[1]}
	else
		tbox_group=$hostname
	fi

	host=${tbox_group%--*}

	create_yaml_variables "$LKP_SRC/hosts/${host}"

	source "$CCI_SRC/providers/$provider/${template}.sh"
)
curl -X PUT "http://${SCHED_HOST:-172.17.0.1}:${SCHED_PORT:-3000}/del_host_mac?mac=${mac}"
