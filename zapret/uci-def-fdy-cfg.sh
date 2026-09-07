#!/bin/sh
# uci-defaults: create the base /etc/config/fdy for the FDY add-on
# (Flowseal strategy sync/testing) so LuCI forms and scripts see the
# config even before any fdy-*.sh has run.

[ -f /etc/config/fdy ] || touch /etc/config/fdy

uci -q get fdy.sync >/dev/null 2>&1 || {
	uci set fdy.sync=sync
	uci set fdy.sync.enabled='0'
	uci set fdy.sync.time='04:30'
	uci set fdy.sync.mirror=''
	uci set fdy.sync.autotest='0'
	uci set fdy.sync.restart_after='0'
}

uci -q get fdy.test >/dev/null 2>&1 || {
	uci set fdy.test=test
	uci set fdy.test.curl_timeout='4'
	uci set fdy.test.start_wait='6'
	uci set fdy.test.max_parallel='8'
	uci set fdy.test.targets='/opt/zapret/fdy/targets.txt'
}

uci -q get fdy.general >/dev/null 2>&1 || {
	uci set fdy.general=general
	uci set fdy.general.gamefilter='off'
}

uci commit fdy

exit 0
