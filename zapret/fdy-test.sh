#!/bin/sh
# fdy-test.sh - live testing of strategies converted from Flowseal bat files.
#
# Port of "utils/test zapret.ps1" (Flowseal) to OpenWrt busybox ash.
# For every strategy in $FDY_BASE/strategies/*.opt:
#   - apply it (uci zapret.config.NFQWS_* + sync_config.sh + service restart)
#   - probe targets from targets.txt (curl HTTP/TLS + ping), in parallel chunks
#   - score = ok*10 + ping_ok - err*2 (floor 0)
# After the run the best strategy is applied; the original config is restored
# when the run is aborted (trap) or when no strategy scores > 0.
#
# Usage:
#   fdy-test.sh              full run over all strategies
#   fdy-test.sh --single N   test one strategy, then restore original config
#   fdy-test.sh --apply N    apply strategy N and keep it
#   fdy-test.sh --selftest   offline self-test (mocked probes, temp base)
#
# Files:
#   live log   /tmp/fdy_test_live.log   (last line: "END rc=<n>")
#   results    $FDY_BASE/results/test_<ts>.txt and last.json
#   journal    $FDY_BASE/logs/test.log
#
# UCI fdy.test: curl_timeout(4) start_wait(6) max_parallel(8) targets(path)
# UCI fdy.general: applied_name - name of last applied strategy (written here)

FDY_ZAPRET_BASE="${FDY_ZAPRET_BASE:-/opt/zapret}"

[ -f "$FDY_ZAPRET_BASE/fdy-lib.sh" ] && . "$FDY_ZAPRET_BASE/fdy-lib.sh"

FDY_BASE="${FDY_BASE:-$FDY_ZAPRET_BASE/fdy}"
FDY_STRAT="$FDY_BASE/strategies"
FDY_RESULTS="$FDY_BASE/results"
FDY_TEST_LOG="$FDY_BASE/logs/test.log"
LIVE_LOG="/tmp/fdy_test_live.log"
LOCK_DIR="/tmp/fdy_test.lock"
BACKUP_FILE="/tmp/fdy_backup_orig.sh"

# --- fallback minimal log() when fdy-lib.sh is absent (selftest on a PC) ---
if ! command -v log >/dev/null 2>&1; then
	log()
	{
		local ts
		ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
		printf '[%s] [test] %s\n' "$ts" "$*" >> "$FDY_TEST_LOG" 2>/dev/null
		printf '[%s] %s\n' "$ts" "$*" >&2
	}
fi

# --------------------------------------------------------------------------------------------------
# defaults / uci config

# fdy_test_uci_default <uci_option> <default> [var_name]
# reads uci fdy.test.<uci_option>, creating the section/option with the default
# on first run; assigns to ${var_name:-<uci_option uppercased>}
fdy_test_uci_default()
{
	local opt=$1 def=$2 var=${3:-$(printf '%s' "$1" | tr 'a-z' 'A-Z')}
	local val
	command -v uci >/dev/null 2>&1 || { eval "$var=\$def"; return 0; }
	uci -q show fdy.test >/dev/null 2>&1 || uci set fdy.test=test
	val=$(uci -q get "fdy.test.$opt" 2>/dev/null)
	if [ "$val" = "" ]; then
		uci set "fdy.test.$opt=$def" && uci -q commit fdy
		val=$def
	fi
	eval "$var=\$val"
	return 0
}

CURL_TIMEOUT=4
START_WAIT=6
MAX_PARALLEL=8
TARGETS_FILE="$FDY_BASE/targets.txt"
[ -f "$FDY_ZAPRET_BASE/fdy-lib.sh" ] && {
	fdy_test_uci_default curl_timeout 4 CURL_TIMEOUT
	fdy_test_uci_default start_wait 6 START_WAIT
	fdy_test_uci_default max_parallel 8 MAX_PARALLEL
	fdy_test_uci_default targets "$FDY_BASE/targets.txt" TARGETS_FILE
}
case "$CURL_TIMEOUT" in ''|*[!0-9]*) CURL_TIMEOUT=4 ;; esac
case "$START_WAIT" in ''|*[!0-9]*) START_WAIT=6 ;; esac
case "$MAX_PARALLEL" in ''|*[!0-9]*|0) MAX_PARALLEL=8 ;; esac
[ -f "$TARGETS_FILE" ] || TARGETS_FILE="$FDY_BASE/targets.txt"

# --------------------------------------------------------------------------------------------------
# helpers

live()
{
	printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$*" >> "$LIVE_LOG" 2>/dev/null
	log "$*"
}

now_iso()
{
	date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

json_escape()
{
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ensure_test_dirs()
{
	mkdir -p "$FDY_RESULTS" 2>/dev/null
	mkdir -p "$(dirname "$FDY_TEST_LOG")" 2>/dev/null
	return 0
}

default_targets()
{
	cat > "$TARGETS_FILE" <<'EOF'
# targets.txt - endpoints for fdy-test.sh (Flowseal format)
#   Name = "https://host"   -> HTTP/TLS checks + ping of host
#   Name = "PING:1.2.3.4"   -> ping only
DiscordMain           = "https://discord.com"
DiscordGateway        = "https://gateway.discord.gg"
DiscordCDN            = "https://cdn.discordapp.com"
DiscordUpdates        = "https://updates.discord.com"
YouTubeWeb            = "https://www.youtube.com"
YouTubeShort          = "https://youtu.be"
YouTubeImage          = "https://i.ytimg.com"
YouTubeVideoRedirect  = "https://redirector.googlevideo.com"
GoogleMain            = "https://www.google.com"
GoogleGstatic         = "https://www.gstatic.com"
CloudflareWeb         = "https://www.cloudflare.com"
CloudflareCDN         = "https://cdnjs.cloudflare.com"
CloudflareDNS1111     = "PING:1.1.1.1"
CloudflareDNS1001     = "PING:1.0.0.1"
GoogleDNS8888         = "PING:8.8.8.8"
GoogleDNS8844         = "PING:8.8.4.4"
EOF
}

# curl TLS capability (checked once)
CURL_TLS_OK=""
curl_tls_supported()
{
	[ -n "$CURL_TLS_OK" ] && { [ "$CURL_TLS_OK" = "1" ]; return $?; }
	if curl -V 2>/dev/null | grep -qi 'ssl\|tls'; then
		CURL_TLS_OK=1
	else
		CURL_TLS_OK=0
	fi
	[ "$CURL_TLS_OK" = "1" ]
}

# selftest hook: deterministic pseudo results keyed by strategy+target name
# (defined unconditionally; only used when FDY_SELFTEST=1)
mock_hash()
{
	printf '%s-%s' "$1" "$2" | cksum | cut -d' ' -f1
}

# http_probe <url> <extra curl args...> -> prints token: OK | ERR | SSL | UNSUP
http_probe()
{
	local url=$1 rc out errf
	shift
	errf=$(mktemp /tmp/fdy_curl.XXXXXX 2>/dev/null || printf '/tmp/fdy_curl.%s' $$)
	if [ "${FDY_SELFTEST:-0}" = "1" ]; then
		rm -f "$errf"
		local h
		h=$(mock_hash "$url" "$*")
		case $((h % 5)) in
			0|1|2) printf 'OK' ;;
			3) printf 'ERR' ;;
			*) printf 'OK' ;;
		esac
		return 0
	fi
	out=$(curl -I -s -m "$CURL_TIMEOUT" --connect-timeout 2 \
		-o /dev/null -w '%{http_code}' "$@" "$url" 2>"$errf")
	rc=$?
	err=$(cat "$errf" 2>/dev/null)
	rm -f "$errf"
	if printf '%s' "$err" | grep -qi 'certificate\|SSL\|self[- ]\?signed\|resolve'; then
		printf 'SSL'
		return 0
	fi
	if [ "$rc" = "35" ] || printf '%s' "$err" | grep -qi 'not supported\|unsupported\|unknown option\|unrecognized'; then
		printf 'UNSUP'
		return 0
	fi
	if [ "$rc" = "0" ] && [ "$out" != "000" ] && [ -n "$out" ]; then
		printf 'OK'
		return 0
	fi
	printf 'ERR'
	return 0
}

# ping_probe <host> -> prints 1 (ok) or 0
ping_probe()
{
	local host=$1
	if [ "${FDY_SELFTEST:-0}" = "1" ]; then
		local h
		h=$(mock_hash "$host" ping)
		[ $((h % 6)) -ne 0 ] && printf '1' || printf '0'
		return 0
	fi
	ping -c 1 -W 2 "$host" >/dev/null 2>&1 && printf '1' || printf '0'
	return 0
}

# target_test <name> <value> <outfile>
# appends "<name> <ok> <err> <unsup> <ping_ok>" to outfile
target_test()
{
	local name=$1 value=$2 outfile=$3
	local ok=0 errc=0 unsup=0 pingok=0 tok host
	case "$value" in
	PING:*)
		host=${value#PING:}
		pingok=$(ping_probe "$host")
		;;
	*)
		# HTTP/1.1 probe
		tok=$(http_probe "$value" --http1.1)
		case "$tok" in
			OK) ok=$((ok+1)) ;;
			ERR) errc=$((errc+1)) ;;
			SSL) errc=$((errc+1)) ;;
			UNSUP) unsup=$((unsup+1)) ;;
		esac
		# TLS probes when curl supports TLS
		if curl_tls_supported; then
			tok=$(http_probe "$value" --tlsv1.2 --tls-max 1.2)
			case "$tok" in
				OK) ok=$((ok+1)) ;;
				ERR) errc=$((errc+1)) ;;
				SSL) errc=$((errc+1)) ;;
				UNSUP) unsup=$((unsup+1)) ;;
			esac
			tok=$(http_probe "$value" --tlsv1.3 --tls-max 1.3)
			case "$tok" in
				OK) ok=$((ok+1)) ;;
				ERR) errc=$((errc+1)) ;;
				SSL) errc=$((errc+1)) ;;
				UNSUP) unsup=$((unsup+1)) ;;
			esac
		fi
		host=$(printf '%s' "$value" | sed -e 's|^https\?://||' -e 's|/.*$||')
		pingok=$(ping_probe "$host")
		;;
	esac
	printf '%s %s %s %s %s\n' "$name" "$ok" "$errc" "$unsup" "$pingok" >> "$outfile"
}

# run_targets <outfile> - parses TARGETS_FILE, runs probes in chunks of MAX_PARALLEL
run_targets()
{
	local outfile=$1
	local names="" values="" n tname tvalue chunk=0
	rm -f "$outfile"
	[ -f "$TARGETS_FILE" ] || default_targets
	while IFS= read -r line; do
		case "$line" in ''|'#'*) continue ;; esac
		tname=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p')
		tvalue=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*[A-Za-z0-9_]*[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p')
		[ -n "$tname" ] && [ -n "$tvalue" ] || continue
		names="$names $tname"
		eval "FDY_TVAL_$tname=\"\$tvalue\""
	done < "$TARGETS_FILE"
	for n in $names; do
		eval "tvalue=\$FDY_TVAL_$n"
		target_test "$n" "$tvalue" "$outfile" &
		chunk=$((chunk+1))
		if [ "$chunk" -ge "$MAX_PARALLEL" ]; then
			wait
			chunk=0
		fi
	done
	wait
	return 0
}

# --------------------------------------------------------------------------------------------------
# service handling

service_ok()
{
	[ "${FDY_NOAPPLY:-0}" = "1" ] && return 0
	[ -x /etc/init.d/zapret ] && return 0
	return 1
}

# apply_opt <name> -> 0 ok
apply_opt()
{
	# NOTE: busybox ash evaluates all assignments in a single `local`
	# statement before any of them takes effect, so dependent values
	# must be assigned in separate statements
	local name=$1
	local optf="$FDY_STRAT/$name.opt"
	local i
	[ -f "$optf" ] || { log "ERROR: strategy file not found: $optf"; return 2; }
	if [ "${FDY_NOAPPLY:-0}" = "1" ]; then
		log "selftest: skip apply $name"
		return 0
	fi
	if command -v apply_strategy_file >/dev/null 2>&1; then
		apply_strategy_file "$optf" || return 1
	else
		uci set zapret.config.NFQWS_OPT="$(sed -n 's/^NFQWS_OPT="\(.*\)"$/\1/p' "$optf")" || return 1
		uci -q commit zapret || return 1
	fi
	uci set fdy.general.applied_name="$name" 2>/dev/null
	uci -q commit fdy 2>/dev/null
	/etc/init.d/zapret restart >> "$FDY_TEST_LOG" 2>&1 || return 1
	i=0
	while [ "$i" -lt "$START_WAIT" ]; do
		sleep 1
		pidof nfqws >/dev/null 2>&1 && return 0
		i=$((i+1))
	done
	log "ERROR: nfqws did not start for strategy $name"
	# surface the daemon exit reason from the system log (procd sends
	# the child's stderr there) - last 5 nfqws-related lines
	logread 2>/dev/null | grep -i 'nfqws' | tail -5 | while read -r ln; do
		log "  syslog: $ln"
	done
	return 1
}

backup_orig()
{
	[ "${FDY_NOAPPLY:-0}" = "1" ] && return 0
	rm -f "$BACKUP_FILE" "$BACKUP_FILE.stamp"
	local o t u
	o=$(uci -q get zapret.config.NFQWS_OPT 2>/dev/null)
	t=$(uci -q get zapret.config.NFQWS_PORTS_TCP 2>/dev/null)
	u=$(uci -q get zapret.config.NFQWS_PORTS_UDP 2>/dev/null)
	{
		printf "FDY_BAK_OPT='%s'\n" "$(printf '%s' "$o" | sed -e "s/'/'\\\\''/g")"
		printf "FDY_BAK_TCP='%s'\n" "$(printf '%s' "$t" | sed -e "s/'/'\\\\''/g")"
		printf "FDY_BAK_UDP='%s'\n" "$(printf '%s' "$u" | sed -e "s/'/'\\\\''/g")"
	} > "$BACKUP_FILE"
	# stamp: only the process that wrote the backup may restore it
	printf '%s\n' "$$" > "$BACKUP_FILE.stamp"
	return 0
}

restore_orig()
{
	[ "${FDY_NOAPPLY:-0}" = "1" ] && return 0
	[ -f "$BACKUP_FILE" ] || { live "no backup to restore (config left unchanged)"; return 1; }
	if [ -f "$BACKUP_FILE.stamp" ] && [ "$(cat "$BACKUP_FILE.stamp" 2>/dev/null)" != "$$" ]; then
		live "stale backup ignored (written by another run, pid $(cat "$BACKUP_FILE.stamp"))"
		return 1
	fi
	. "$BACKUP_FILE"
	uci set zapret.config.NFQWS_OPT="$FDY_BAK_OPT" 2>/dev/null
	uci set zapret.config.NFQWS_PORTS_TCP="$FDY_BAK_TCP" 2>/dev/null
	uci set zapret.config.NFQWS_PORTS_UDP="$FDY_BAK_UDP" 2>/dev/null
	uci -q commit zapret 2>/dev/null
	[ -f "$FDY_ZAPRET_BASE/sync_config.sh" ] && sh "$FDY_ZAPRET_BASE/sync_config.sh" >/dev/null 2>&1
	/etc/init.d/zapret restart >/dev/null 2>&1
	rm -f "$BACKUP_FILE" "$BACKUP_FILE.stamp"
	live "original config restored"
	return 0
}

# --------------------------------------------------------------------------------------------------
# reporting

write_last_json()
{
	# $1 started  $2 finished  $3 best  $4 best_score  $5 aborted(0/1)  $6 error
	# reads $SCORE_FILE lines: "<name> <score> <ok> <err> <unsup> <ping_ok> <applied>"
	local jf="$FDY_RESULTS/last.json" first=1 line name score ok errc unsup pingok appl
	{
		printf '{"started":"%s","finished":"%s","best":"%s","best_score":%s,"aborted":%s,"error":"%s","strategies":[' \
			"$1" "$2" "$(json_escape "$3")" "${4:-0}" "$5" "$(json_escape "$6")"
		while read -r name score ok errc unsup pingok appl; do
			[ -n "$name" ] || continue
			[ "$first" = "1" ] || printf ','
			first=0
			printf '{"name":"%s","score":%s,"ok":%s,"err":%s,"unsup":%s,"ping_ok":%s,"applied":%s}' \
				"$(json_escape "$name")" "${score:-0}" "${ok:-0}" "${errc:-0}" "${unsup:-0}" "${pingok:-0}" "${appl:-false}"
		done < "$SCORE_FILE"
		printf ']}\n'
	} > "$jf.tmp" && mv "$jf.tmp" "$jf"
	return 0
}

# --------------------------------------------------------------------------------------------------
# main flows

acquire_lock()
{
	mkdir "$LOCK_DIR" 2>/dev/null || {
		printf '%s\n' "ERROR: another fdy-test run is active (lock $LOCK_DIR)"
		return 1
	}
	printf '%s\n' $$ > "$LOCK_DIR/pid" 2>/dev/null
	I_OWN_LOCK=1
	return 0
}

release_lock()
{
	# only the owner may remove the lock; a failed acquire must not
	# destroy the incumbent's lock on its way out
	[ "${I_OWN_LOCK:-0}" = "1" ] || return 0
	rm -rf "$LOCK_DIR" 2>/dev/null
	I_OWN_LOCK=0
	return 0
}

FINISHED=0
ABORTED=0
on_exit()
{
	if [ "$FINISHED" != "1" ]; then
		ABORTED=1
		live "test run interrupted - restoring original config"
		restore_orig
	fi
	release_lock
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

score_strategy()
{
	# $1 name; reads $TARGET_RES -> prints "<score> <ok> <err> <unsup> <ping_ok>"
	local name=$1 line ok=0 errc=0 unsup=0 pingok=0 score
	while read -r line; do
		set -- $line
		# name ok err unsup ping
		ok=$((ok + $2))
		errc=$((errc + $3))
		unsup=$((unsup + $4))
		pingok=$((pingok + $5))
	done < "$TARGET_RES"
	score=$(( ok * 10 + pingok - errc * 2 ))
	[ "$score" -lt 0 ] && score=0
	printf '%s %s %s %s %s' "$score" "$ok" "$errc" "$unsup" "$pingok"
	return 0
}

cmd_apply()
{
	local name=$1
	service_ok || { printf '%s\n' "ERROR: /etc/init.d/zapret not found"; exit 2; }
	[ -f "$FDY_STRAT/$name.opt" ] || { printf '%s\n' "ERROR: unknown strategy: $name"; exit 2; }
	ensure_test_dirs
	backup_orig
	if apply_opt "$name"; then
		live "strategy $name applied and running"
		printf '%s\n' "OK: strategy $name applied"
		rm -f "$BACKUP_FILE" "$BACKUP_FILE.stamp"
		exit 0
	else
		live "ERROR: strategy $name failed to start - restoring original"
		restore_orig
		printf '%s\n' "ERROR: strategy $name failed to start, original config restored"
		exit 3
	fi
}

cmd_single()
{
	local name=$1 started finished
	service_ok || { printf '%s\n' "ERROR: /etc/init.d/zapret not found"; exit 2; }
	[ -f "$FDY_STRAT/$name.opt" ] || { printf '%s\n' "ERROR: unknown strategy: $name"; exit 2; }
	ensure_test_dirs
	acquire_lock || exit 5
	: > "$LIVE_LOG"
	started=$(now_iso)
	TARGET_RES="/tmp/fdy_targets.$$.res"
	backup_orig
	if apply_opt "$name"; then
		live "=== [1/1] $name ==="
		run_targets "$TARGET_RES"
		local res
		res=$(score_strategy "$name")
		live "$name score: $res"
	else
		rm -f "$TARGET_RES"
		restore_orig
		FINISHED=1
		live "END rc=1"
		exit 1
	fi
	restore_orig
	finished=$(now_iso)
	{
		printf 'SINGLE TEST %s\n  strategy: %s\n  result: %s\n' "$(now_iso)" "$name" "$(score_strategy "$name")"
	} >> "$FDY_RESULTS/single_${name}.txt"
	rm -f "$TARGET_RES"
	FINISHED=1
	live "END rc=0"
	exit 0
}

cmd_full()
{
	local list_file="$FDY_STRAT/list.txt" names n total i=0 started finished
	local best="" best_score=-1 best_err=0
	service_ok || { printf '%s\n' "ERROR: /etc/init.d/zapret not found"; exit 2; }
	[ -f "$list_file" ] || { printf '%s\n' "ERROR: no strategies converted yet (run sync first)"; exit 2; }
	names=$(sort "$list_file")
	[ -n "$names" ] || { printf '%s\n' "ERROR: strategy list is empty"; exit 2; }
	total=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
	ensure_test_dirs
	acquire_lock || exit 5
	# self-heal: the Windows archive ships no *-user.txt, and nfqws exits
	# when a --hostlist/--ipset file is missing or empty, which makes every
	# strategy fail to start. Create them before touching any strategy.
	if command -v fdy_ensure_user_lists >/dev/null 2>&1; then
		fdy_ensure_user_lists "$FDY_ZAPRET_BASE/fdy/current/lists"
	fi
	: > "$LIVE_LOG"
	started=$(now_iso)
	SCORE_FILE="/tmp/fdy_scores.$$.txt"
	TARGET_RES="/tmp/fdy_targets.$$.res"
	: > "$SCORE_FILE"
	live "ZAPRET FDY CONFIG TESTS: $total strategies"
	live "WARNING: internet in LAN will briefly drop on every strategy switch"
	backup_orig
	for n in $names; do
		i=$((i+1))
		live "=== [$i/$total] $n ==="
		if apply_opt "$n"; then
			run_targets "$TARGET_RES"
			set -- $(score_strategy "$n")
			# score ok err unsup ping
			printf '%s %s %s %s %s %s false\n' "$n" "$1" "$2" "$3" "$4" "$5" >> "$SCORE_FILE"
			live "$n : score=$1 ok=$2 err=$3 unsup=$4 ping_ok=$5"
			if [ "$1" -gt "$best_score" ] || { [ "$1" -eq "$best_score" ] && [ "$3" -lt "$best_err" ]; }; then
				best="$n"; best_score=$1; best_err=$3
			fi
		else
			printf '%s 0 0 0 0 0 false\n' "$n" >> "$SCORE_FILE"
			live "$n : START FAILED (score=0)"
		fi
		rm -f "$TARGET_RES"
	done
	# summary
	live "=== ANALYTICS ==="
	while read -r line; do
		live "$line"
	done < "$SCORE_FILE"
	if [ "$best_score" -le 0 ] || [ -z "$best" ]; then
		live "no working strategy found - restoring original config"
		restore_orig
		finished=$(now_iso)
		write_last_json "$started" "$finished" "" 0 0 "no strategy scored above zero"
		report_file="$FDY_RESULTS/test_$(date '+%Y%m%d_%H%M%S').txt"
		cp "$SCORE_FILE" "$report_file" 2>/dev/null
		rm -f "$SCORE_FILE" "$TARGET_RES"
		FINISHED=1
		live "END rc=1"
		exit 1
	fi
	live "Best config: $best (score $best_score)"
	if apply_opt "$best"; then
		# mark applied in score file
		awk -v b="$best" '
			$1 == b { $7 = "true" }
			{ print }
		' "$SCORE_FILE" > "$SCORE_FILE.new" && mv "$SCORE_FILE.new" "$SCORE_FILE"
		live "strategy $best applied"
	else
		live "ERROR: best strategy failed to apply - restoring original"
		restore_orig
	fi
	finished=$(now_iso)
	write_last_json "$started" "$finished" "$best" "$best_score" 0 ""
	report_file="$FDY_RESULTS/test_$(date '+%Y%m%d_%H%M%S').txt"
	{
		printf 'FDY TEST REPORT %s - %s\n' "$started" "$finished"
		printf 'Best strategy: %s (score %s)\n\n' "$best" "$best_score"
		printf '%-28s %6s %4s %4s %4s %4s\n' STRATEGY SCORE OK ERR UNSUP PING
		awk '{ printf "%-28s %6s %4s %4s %4s %4s\n", $1, $2, $3, $4, $5, $6 }' "$SCORE_FILE"
	} > "$report_file"
	rm -f "$SCORE_FILE" "$TARGET_RES"
	rm -f "$BACKUP_FILE"
	FINISHED=1
	live "results: $report_file"
	live "END rc=0"
	exit 0
}

cmd_selftest()
{
	local tmpbase=/tmp/fdy_selftest.$$ strat
	rm -rf "$tmpbase"
	mkdir -p "$tmpbase/strategies" "$tmpbase/results" "$tmpbase/logs"
	for strat in alpha beta; do
		cat > "$tmpbase/strategies/$strat.opt" <<EOF
# FDY_STRATEGY_V1
# NAME=$strat
# PORTS_TCP=80,443
# PORTS_UDP=443
NFQWS_OPT="--filter-tcp=443 --dpi-desync=fake"
EOF
		printf '%s\n' "$strat" >> "$tmpbase/strategies/list.txt"
	done
	cat > "$tmpbase/targets.txt" <<'EOF'
TestA = "https://example.com"
TestB = "PING:1.1.1.1"
EOF
	FDY_BASE="$tmpbase"
	FDY_STRAT="$tmpbase/strategies"
	FDY_RESULTS="$tmpbase/results"
	FDY_TEST_LOG="$tmpbase/logs/test.log"
	TARGETS_FILE="$tmpbase/targets.txt"
	FDY_NOAPPLY=1
	FDY_SELFTEST=1
	ensure_test_dirs
	acquire_lock || exit 5
	: > "$LIVE_LOG"
	SCORE_FILE="$tmpbase/scores.txt"
	: > "$SCORE_FILE"
	TARGET_RES="$tmpbase/targets.res"
	local best="" best_score=-1 n
	for n in alpha beta; do
		run_targets "$TARGET_RES"
		set -- $(score_strategy "$n")
		printf '%s %s %s %s %s %s false\n' "$n" "$1" "$2" "$3" "$4" "$5" >> "$SCORE_FILE"
		if [ "$1" -gt "$best_score" ]; then best="$n"; best_score=$1; fi
		rm -f "$TARGET_RES"
	done
	if [ -n "$best" ] && [ "$best_score" -ge 0 ]; then
		printf 'SELFTEST OK: best=%s score=%s\n' "$best" "$best_score"
		cat "$SCORE_FILE"
		release_lock
		rm -rf "$tmpbase"
		FINISHED=1
		exit 0
	fi
	printf 'SELFTEST FAILED\n'
	cat "$SCORE_FILE"
	release_lock
	rm -rf "$tmpbase"
	FINISHED=1
	exit 1
}

# --------------------------------------------------------------------------------------------------

case "${1:-}" in
	--apply)
		[ -n "${2:-}" ] || { printf '%s\n' "usage: fdy-test.sh --apply <strategy>"; exit 64; }
		ensure_test_dirs
		cmd_apply "$2"
		;;
	--single)
		[ -n "${2:-}" ] || { printf '%s\n' "usage: fdy-test.sh --single <strategy>"; exit 64; }
		cmd_single "$2"
		;;
	--selftest)
		cmd_selftest
		;;
	-h|--help|'')
		[ -z "${1:-}" ] || cat <<'EOF'
usage: fdy-test.sh [--apply <name>|--single <name>|--selftest]
EOF
		[ -z "${1:-}" ] && cmd_full
		;;
	*)
		printf '%s\n' "unknown argument: $1 (see --help)"
		exit 64
		;;
esac
