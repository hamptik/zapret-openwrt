#!/bin/sh
# fdy-lib.sh - common library for the "fdy" add-on scripts of zapret-openwrt.
#
# The add-on keeps the Flowseal "zapret-discord-youtube" distributive in sync
# with upstream GitHub releases:
#   https://github.com/Flowseal/zapret-discord-youtube
#
# Data layout (all created on first run, perms 755):
#   /opt/zapret/fdy/current/            unpacked distributive (bat/bin/lists/utils/.service)
#   /opt/zapret/fdy/current/version     release tag of installed copy (i.e. "1.10.2")
#   /opt/zapret/fdy/strategies/         *.opt files produced by fdy-convert.sh
#   /opt/zapret/fdy/logs/sync.log       journal (append)
#   /opt/zapret/fdy/logs/state.json     {"version","synced_at","status","error","last_check"}
#
# UCI options (named section fdy.sync, created with defaults on first run):
#   enabled       0|1      cron-driven sync master switch
#   time          HH:MM    cron run time
#   mirror        URL      proxy prefix put BEFORE github URLs (i.e. https://ghproxy.net/)
#   autotest      0|1      run fdy-test.sh after successful sync
#   restart_after 0|1      restart zapret service after sync (ignored when autotest=1)
#
# Strategy file contract (for fdy-convert.sh): a POSIX-sh fragment which sets
#   FDY_NFQWS_OPT        (fallback: NFQWS_OPT)         -> uci zapret.config.NFQWS_OPT
#   FDY_NFQWS_PORTS_TCP  (fallback: NFQWS_PORTS_TCP)   -> uci zapret.config.NFQWS_PORTS_TCP
#   FDY_NFQWS_PORTS_UDP  (fallback: NFQWS_PORTS_UDP)   -> uci zapret.config.NFQWS_PORTS_UDP
#
# Written for busybox ash (strict POSIX): no arrays, no [[ ]], no local -I.

FDY_TAG="${FDY_TAG:-zapret-fdy}"
FDY_LOG_SRC="${FDY_LOG_SRC:-fdy}"

# base paths (env-overridable for testing, defaults match the router layout)
FDY_ZAPRET_BASE="${FDY_ZAPRET_BASE:-/opt/zapret}"
FDY_BASE="${FDY_BASE:-$FDY_ZAPRET_BASE/fdy}"
FDY_CURRENT="$FDY_BASE/current"
FDY_CURRENT_PREV="$FDY_BASE/current.prev"
FDY_STAGING="$FDY_BASE/staging"
FDY_STAGING_TMP="$FDY_BASE/staging.tmp"
FDY_STRATEGIES="$FDY_BASE/strategies"
FDY_LOGS="$FDY_BASE/logs"
FDY_SYNC_LOG="$FDY_LOGS/sync.log"
FDY_STATE_JSON="$FDY_LOGS/state.json"
FDY_VERSION_FILE="$FDY_CURRENT/version"

# companion scripts / system files
FDY_CONVERT="${FDY_CONVERT:-$FDY_ZAPRET_BASE/fdy-convert.sh}"
FDY_TEST="${FDY_TEST:-$FDY_ZAPRET_BASE/fdy-test.sh}"
FDY_SYNC="${FDY_SYNC:-$FDY_ZAPRET_BASE/fdy-sync.sh}"
FDY_SYNC_CONFIG="${FDY_SYNC_CONFIG:-$FDY_ZAPRET_BASE/sync_config.sh}"
FDY_SERVICE_INITD="${FDY_SERVICE_INITD:-/etc/init.d/zapret}"
CRONTAB_FILE="${CRONTAB_FILE:-/etc/crontabs/root}"
FDY_JSHN="${FDY_JSHN:-/usr/share/libubox/jshn.sh}"

# upstream release info
FDY_API_URL="https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest"
FDY_REL_JSON="/tmp/fdy_release.json"
FDY_DL_FILE="/tmp/fdy_dl.tar.gz"
FDY_DL_SHA="/tmp/fdy_dl.tar.gz.sha256"
FDY_CURL_TIMEOUT="${FDY_CURL_TIMEOUT:-15}"

FDY_CRON_TAG="#zapret-fdy-tag"
FDY_CRON_TMP="${FDY_CRON_TMP:-/tmp/fdy_crontab.tmp}"

# active mirror prefix ("" = direct GitHub), set by fdy-sync.sh from uci
FDY_MIRROR=""

# parsed release info (filled by fdy_release_parse)
FDY_REL_TAG=""
FDY_REL_NAME=""
FDY_REL_URL=""
FDY_REL_DIGEST=""

[ -f "$FDY_JSHN" ] && . "$FDY_JSHN"

# -------------------------------------------------------------------------------------------------------

log()
{
local ts
ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
	if [ -d "$FDY_LOGS" ]; then
		printf '[%s] [%s] %s\n' "$ts" "$FDY_LOG_SRC" "$*" >> "$FDY_SYNC_LOG" 2>/dev/null
	fi
	printf '[%s] %s\n' "$ts" "$*" >&2
}

err()
{
	local ts
	ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
	if [ -d "$FDY_LOGS" ]; then
		printf '[%s] [%s] ERROR: %s\n' "$ts" "$FDY_LOG_SRC" "$*" >> "$FDY_SYNC_LOG" 2>/dev/null
	fi
	logger -t "$FDY_TAG" -s -p daemon.err "$*" 2>/dev/null || printf 'ERROR: %s\n' "$*" >&2
}

die()
{
	err "$@"
	exit 1
}

fdy_fail()
{
	touch_state status error >/dev/null 2>&1
	touch_state error "$*" >/dev/null 2>&1
	err "$@"
	exit 1
}

fdy_cleanup()
{
	rm -f "$FDY_REL_JSON" "$FDY_DL_FILE" "$FDY_DL_SHA" 2>/dev/null
	rm -rf "$FDY_STAGING_TMP" "$FDY_STAGING" 2>/dev/null
}

fdy_setup_traps()
{
	trap 'fdy_cleanup' EXIT
	trap 'fdy_cleanup; exit 129' HUP
	trap 'fdy_cleanup; exit 130' INT
	trap 'fdy_cleanup; exit 143' TERM
}

fdy_now_iso()
{
	date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

ensure_dirs()
{
	local d
	for d in "$FDY_BASE" "$FDY_STRATEGIES" "$FDY_LOGS"; do
		[ -d "$d" ] || mkdir -p "$d" || die "cannot create directory: $d"
		chmod 755 "$d" 2>/dev/null
	done
	if [ ! -f "$FDY_STATE_JSON" ]; then
		printf '{"version":"","synced_at":"","status":"","error":"","last_check":""}\n' > "$FDY_STATE_JSON" 2>/dev/null
	fi
	return 0
}

# uci_get_default <option> <default>
# reads uci fdy.sync.<option>, creating the section and the default on first run
uci_get_default()
{
	local option=$1 defval=$2 val
	command -v uci >/dev/null 2>&1 || { printf '%s' "$defval"; return 0; }
	uci -q show "fdy.sync" >/dev/null 2>&1 || uci set fdy.sync=sync
	val=$( uci -q get "fdy.sync.$option" 2>/dev/null )
	if [ "$val" = "" ]; then
		uci set "fdy.sync.$option=$defval" && uci -q commit fdy
		val=$defval
	fi
	printf '%s' "$val"
	return 0
}

fdy_uci_defaults()
{
	command -v uci >/dev/null 2>&1 || return 1
	uci -q show fdy.sync >/dev/null 2>&1 || uci set fdy.sync=sync
	uci_get_default enabled 0 >/dev/null
	uci_get_default time '04:30' >/dev/null
	uci_get_default mirror '' >/dev/null
	uci_get_default autotest 0 >/dev/null
	uci_get_default restart_after 0 >/dev/null
	return 0
}

# prints the tag of the currently installed distributive ("" when not installed)
fdy_current_version()
{
	local ver=""
	if [ -f "$FDY_VERSION_FILE" ]; then
		ver=$( head -n 1 "$FDY_VERSION_FILE" 2>/dev/null | tr -d '\r' )
	fi
	printf '%s' "$ver"
	return 0
}

# fdy_ver_cmp <local_ver> <remote_ver> -> prints L (local older), E (equal), G (local newer)
fdy_ver_cmp()
{
	local v1="${1:-}" v2="${2:-}" oIFS
	local a b c x y z
	case "$v1" in [vV]*) v1=${v1#[vV]} ;; esac
	case "$v2" in [vV]*) v2=${v2#[vV]} ;; esac
	v1=$( printf '%s' "$v1" | cut -d- -f1 )
	v2=$( printf '%s' "$v2" | cut -d- -f1 )
	oIFS=$IFS ; IFS=. ; set -- $v1 ; IFS=$oIFS
	a=${1:-0} ; b=${2:-0} ; c=${3:-0}
	oIFS=$IFS ; IFS=. ; set -- $v2 ; IFS=$oIFS
	x=${1:-0} ; y=${2:-0} ; z=${3:-0}
	a=${a%%[!0-9]*} ; b=${b%%[!0-9]*} ; c=${c%%[!0-9]*}
	x=${x%%[!0-9]*} ; y=${y%%[!0-9]*} ; z=${z%%[!0-9]*}
	: ${a:=0} ; : ${b:=0} ; : ${c:=0} ; : ${x:=0} ; : ${y:=0} ; : ${z:=0}
	if [ "$a" -gt "$x" ]; then printf 'G' ; return 0 ; fi
	if [ "$a" -lt "$x" ]; then printf 'L' ; return 0 ; fi
	if [ "$b" -gt "$y" ]; then printf 'G' ; return 0 ; fi
	if [ "$b" -lt "$y" ]; then printf 'L' ; return 0 ; fi
	if [ "$c" -gt "$z" ]; then printf 'G' ; return 0 ; fi
	if [ "$c" -lt "$z" ]; then printf 'L' ; return 0 ; fi
	printf 'E'
	return 0
}

# touch_state <key> <value> - atomically updates a top-level string key of state.json
touch_state()
{
	local key=$1 value=$2
	local tmp="$FDY_STATE_JSON.tmp"
	[ -n "$key" ] || return 1
	[ -d "$FDY_LOGS" ] || return 1
	command -v json_load >/dev/null 2>&1 || return 1
	if [ ! -s "$FDY_STATE_JSON" ]; then
		printf '{"version":"","synced_at":"","status":"","error":"","last_check":""}\n' > "$FDY_STATE_JSON" 2>/dev/null
	fi
	json_load "$( cat "$FDY_STATE_JSON" 2>/dev/null )" >/dev/null 2>&1 || json_load '{}'
	json_add_string "$key" "$value"
	if json_dump > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
		mv "$tmp" "$FDY_STATE_JSON" || { rm -f "$tmp"; return 1; }
		return 0
	fi
	rm -f "$tmp"
	return 1
}

# parses $FDY_REL_JSON, fills FDY_REL_TAG / FDY_REL_NAME / FDY_REL_URL / FDY_REL_DIGEST
# selects the *.tar.gz asset; digest ("sha256:...") is mandatory
fdy_release_parse()
{
	local found=0 idx_list key aname
	FDY_REL_TAG="" ; FDY_REL_NAME="" ; FDY_REL_URL="" ; FDY_REL_DIGEST=""
	command -v json_load >/dev/null 2>&1 || { err "jshn.sh is not available"; return 1; }
	[ -s "$FDY_REL_JSON" ] || { err "release info file is empty"; return 1; }
	if ! json_load "$( cat "$FDY_REL_JSON" )" >/dev/null 2>&1; then
		err "release info: invalid JSON"
		return 1
	fi
	if ! json_get_var FDY_REL_TAG tag_name || [ "$FDY_REL_TAG" = "" ]; then
		json_cleanup
		err "release info: tag_name not found (rate limit?)"
		return 1
	fi
	if ! json_select assets; then
		json_cleanup
		err "release $FDY_REL_TAG: no assets"
		return 1
	fi
	json_get_keys idx_list
	for key in $idx_list; do
		json_select "$key" || continue
		json_get_var aname name
		case "$aname" in
			*.tar.gz)
				json_get_var FDY_REL_NAME name
				json_get_var FDY_REL_URL browser_download_url
				json_get_var FDY_REL_DIGEST digest
				found=1
				;;
		esac
		json_select ..
		[ "$found" = "1" ] && break
	done
	json_cleanup
	if [ "$found" != "1" ]; then
		err "release $FDY_REL_TAG: *.tar.gz asset not found"
		return 1
	fi
	if [ "$FDY_REL_URL" = "" ]; then
		err "release $FDY_REL_TAG: asset has no download URL"
		return 1
	fi
	if [ "$FDY_REL_DIGEST" = "" ]; then
		err "release $FDY_REL_TAG: asset has no sha256 digest (API changed?)"
		return 1
	fi
	return 0
}

# fetches release info (curl, 3 attempts, mirror prefix applied) -> fdy_release_parse
fdy_fetch_release()
{
	local attempt url rc=1
	url="$FDY_API_URL"
	if [ -n "$FDY_MIRROR" ]; then
		url="${FDY_MIRROR}${FDY_API_URL}"
	fi
	for attempt in 1 2 3; do
		rm -f "$FDY_REL_JSON"
		log "fetching release info (attempt $attempt/3): $url"
		curl -s --connect-timeout 10 --max-time "$FDY_CURL_TIMEOUT" \
			-H "Accept: application/vnd.github+json" -o "$FDY_REL_JSON" "$url" 2>/dev/null
		if [ $? -eq 0 ] && [ -s "$FDY_REL_JSON" ]; then
			if fdy_release_parse; then
				rc=0
				break
			fi
		fi
		[ "$attempt" != "3" ] && sleep 2
	done
	return $rc
}

# apply_strategy_file <file.opt>
# sources the strategy file, pushes NFQWS options into uci zapret config,
# regenerates /opt/zapret/config via sync_config.sh
apply_strategy_file()
{
	local opt_file=$1 opt_val tcp_val udp_val
	[ -n "$opt_file" ] || { err "apply_strategy_file: strategy file not specified"; return 1; }
	[ -f "$opt_file" ] || { err "apply_strategy_file: file not found: $opt_file"; return 1; }
	sh -n "$opt_file" 2>/dev/null || { err "apply_strategy_file: syntax error in $opt_file"; return 1; }
	FDY_NFQWS_OPT="" ; FDY_NFQWS_PORTS_TCP="" ; FDY_NFQWS_PORTS_UDP=""
	NFQWS_OPT="" ; NFQWS_PORTS_TCP="" ; NFQWS_PORTS_UDP=""
	. "$opt_file" || { err "apply_strategy_file: cannot source $opt_file"; return 1; }
	opt_val=${FDY_NFQWS_OPT:-$NFQWS_OPT}
	tcp_val=${FDY_NFQWS_PORTS_TCP:-$NFQWS_PORTS_TCP}
	udp_val=${FDY_NFQWS_PORTS_UDP:-$NFQWS_PORTS_UDP}
	if [ "$opt_val" = "" ]; then
		err "apply_strategy_file: NFQWS_OPT is empty in $opt_file"
		return 1
	fi
	command -v uci >/dev/null 2>&1 || { err "apply_strategy_file: uci not available"; return 1; }
	uci set zapret.config.NFQWS_OPT="$opt_val" || return 1
	if [ "$tcp_val" != "" ]; then
		uci set zapret.config.NFQWS_PORTS_TCP="$tcp_val" || return 1
	fi
	if [ "$udp_val" != "" ]; then
		uci set zapret.config.NFQWS_PORTS_UDP="$udp_val" || return 1
	fi
	uci -q commit zapret || return 1
	if [ -f "$FDY_SYNC_CONFIG" ]; then
		sh "$FDY_SYNC_CONFIG" >> "$FDY_SYNC_LOG" 2>&1 || \
			{ err "apply_strategy_file: sync_config.sh failed"; return 1; }
	else
		err "apply_strategy_file: $FDY_SYNC_CONFIG not found"
		return 1
	fi
	log "strategy applied: $opt_file"
	return 0
}
