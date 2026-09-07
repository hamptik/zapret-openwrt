#!/bin/sh
# fdy-convert.sh - Flowseal general*.bat (winws.exe) -> nfqws .opt strategies
#
# Scans $FDY_BASE/current/general*.bat, converts each to
# $FDY_BASE/strategies/<safe-name>.opt and rebuilds strategies/list.txt.
# Strict POSIX sh (busybox ash compatible). Base dir overridable for testing:
#   FDY_BASE=/tmp/fdy_test /bin/sh fdy-convert.sh
#
# .opt format:
#   # FDY_STRATEGY_V1
#   # NAME=<original bat base name>
#   # PORTS_TCP=<union of ports from --wf-tcp, junk port 12 dropped>
#   # PORTS_UDP=<union of ports from --wf-udp, junk port 12 dropped>
#   NFQWS_OPT="<single line of nfqws args, sh double-quoted string>"

FDY_BASE="${FDY_BASE:-/opt/zapret/fdy}"
CUR="$FDY_BASE/current"
STRAT="$FDY_BASE/strategies"
LOGDIR="$FDY_BASE/logs"

# Windows paths inside bat files are rewritten to these (trailing slash kept)
BIN_PATH="/opt/zapret/fdy/current/bin/"
LISTS_PATH="/opt/zapret/fdy/current/lists/"

tmpf="$STRAT/.tmp.conv.$$"
errf="$STRAT/.err.conv.$$"
names_tmp="$STRAT/.names.tmp.$$"
trap 'rm -f "$tmpf" "$errf" "$names_tmp"' EXIT INT TERM

# optional shared lib; fallback log() if it does not provide one.
# NOTE: plain `type log` also matches external binaries (macOS /usr/bin/log,
# OpenWrt log applet). Match the word "function": busybox/bash say
# "log is a function", dash says "log is a shell function".
FDY_LIB="${FDY_LIB:-${FDY_ZAPRET_BASE:-/opt/zapret}/fdy-lib.sh}"
if [ -f "$FDY_LIB" ]; then
	. "$FDY_LIB"
fi
case "$(type log 2>/dev/null)" in
	*function*) ;;
	*)
		log() {
			mkdir -p "$LOGDIR"
			printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGDIR/convert.log"
		}
		;;
esac

mkdir -p "$STRAT" "$LOGDIR" || exit 1

# gamefilter mode: uci fdy.general.gamefilter = off|all|tcp|udp (default off).
# bat semantics (service.bat): off -> GameFilterTCP=GameFilterUDP=12 (junk port,
# section never matches - by design); on -> 1024-65535 for enabled side(s).
GF=""
if command -v uci >/dev/null 2>&1; then
	GF="$(uci -q get fdy.general.gamefilter 2>/dev/null)" || GF=off
fi
[ -n "$GF" ] || GF=off
case "$GF" in
	off|all|tcp|udp) ;;
	*) GF=off ;;
esac
case "$GF" in
	all) GFTCP="1024-65535"; GFUDP="1024-65535" ;;
	tcp) GFTCP="1024-65535"; GFUDP="12" ;;
	udp) GFTCP="12"; GFUDP="1024-65535" ;;
	*)   GFTCP="12"; GFUDP="12" ;;
esac
log "start: base=$FDY_BASE gamefilter=$GF (GFTCP=$GFTCP GFUDP=$GFUDP)"

converted=0
errors=0
total=0
baseline_ok=1
: > "$names_tmp"

for f in "$CUR"/general*.bat; do
	[ -f "$f" ] || continue
	total=$((total + 1))
	base=${f##*/}
	base=${base%.bat}

	# safe file name: lower, space -> __, () dropped, rest of junk -> _
	safe=$(printf '%s' "$base" \
		| tr '[:upper:]' '[:lower:]' \
		| sed -e 's/ /__/g' -e 's/[()]//g' -e 's/[^a-z0-9._-]/_/g')
	if [ -z "$safe" ]; then
		errors=$((errors + 1))
		log "ERROR: cannot make safe name for: $base"
		[ "$base" = "general" ] && baseline_ok=0
		continue
	fi

	if awk -v binpath="$BIN_PATH" -v listspath="$LISTS_PATH" \
		-v gftcp="$GFTCP" -v gfudp="$GFUDP" -v name="$base" '
	function addport(proto, p) {
		if (p == "" || p == "12") return
		# 1024-65535 only when gamefilter is enabled for that side
		if (p == "1024-65535") {
			if (proto == "tcp" && gftcp == "12") return
			if (proto == "udp" && gfudp == "12") return
		}
		if ((proto SUBSEP p) in seenp) return
		seenp[proto SUBSEP p] = 1
		if (proto == "tcp") { ntcp++; tcpp[ntcp] = p }
		else { nudp++; udpp[nudp] = p }
	}
	function harvest(val, proto,   m, parts, i, p) {
		m = split(val, parts, ",")
		for (i = 1; i <= m; i++) {
			p = parts[i]
			gsub(/^[ \t]+/, "", p)
			gsub(/[ \t]+$/, "", p)
			addport(proto, p)
		}
	}
	BEGIN { found = 0; ntcp = 0; nudp = 0 }
	{
		line = $0
		sub(/\r$/, "", line)
		# join bat continuations: trailing ^ glues the next line
		while (line ~ /\^[ \t]*$/) {
			sub(/\^[ \t]*$/, "", line)
			if ((getline nxt) <= 0) break
			sub(/\r$/, "", nxt)
			line = line " " nxt
		}
		if (!found && line ~ /winws\.exe/) {
			i0 = index(line, "winws.exe") + 9
			args = substr(line, i0)
			sub(/^[ \t]+/, "", args)
			if (substr(args, 1, 1) == "\"") args = substr(args, 2)
			sub(/^[ \t]+/, "", args)
			found = 1
		}
	}
	END {
		if (!found) {
			print "no winws.exe command found" > "/dev/stderr"
			exit 3
		}
		# resolve game filter vars first (port harvesting relies on it)
		gsub(/%GameFilterTCP%/, gftcp, args)
		gsub(/%GameFilterUDP%/, gfudp, args)
		n = split(args, tok, " ")
		opt = ""
		for (i = 1; i <= n; i++) {
			t = tok[i]
			if (t == "") continue
			# WinDivert-only flags: do not carry over, harvest ports instead
			if (t ~ /^--wf-tcp=/) { harvest(substr(t, 10), "tcp"); continue }
			if (t ~ /^--wf-udp=/) { harvest(substr(t, 10), "udp"); continue }
			# bat escapes: ^! is a literal !, stray ^ is dropped
			gsub(/\^!/, "!", t)
			gsub(/\^/, "", t)
			# path substitutions -> absolute unix paths
			gsub(/%BIN%/, binpath, t)
			gsub(/%LISTS%/, listspath, t)
			gsub(/%~dp0bin\\/, binpath, t)
			gsub(/%~dp0lists\\/, listspath, t)
			gsub(/%GameFilterTCP%/, gftcp, t)
			gsub(/%GameFilterUDP%/, gfudp, t)
			# quotes around values are dropped (no spaces inside values)
			gsub(/"/, "", t)
			# escape for a sh double-quoted string
			gsub(/\\/, "\\\\", t)
			gsub(/"/, "\\\"", t)
			gsub(/\$/, "\\$", t)
			gsub(/`/, "\\`", t)
			if (t ~ /%/) {
				print "unresolved variable in: " t > "/dev/stderr"
				failed = 1
				continue
			}
			opt = (opt == "" ? t : opt " " t)
		}
		if (failed) exit 4
		if (opt == "") {
			print "empty argument list" > "/dev/stderr"
			exit 5
		}
		pt = ""
		for (k = 1; k <= ntcp; k++) pt = pt (k > 1 ? "," : "") tcpp[k]
		pu = ""
		for (k = 1; k <= nudp; k++) pu = pu (k > 1 ? "," : "") udpp[k]
		print "# FDY_STRATEGY_V1"
		print "# NAME=" name
		print "NFQWS_PORTS_TCP=\"" pt "\""
		print "NFQWS_PORTS_UDP=\"" pu "\""
		print "NFQWS_OPT=\"" opt "\""
	}
	' "$f" > "$tmpf" 2> "$errf" && [ -s "$tmpf" ]; then
		rm -f "$errf"
		mv "$tmpf" "$STRAT/$safe.opt"
		printf '%s\n' "$safe" >> "$names_tmp"
		converted=$((converted + 1))
		log "converted: $base -> $safe.opt"
	else
		awkerr=$(cat "$errf" 2>/dev/null)
		rm -f "$errf" "$tmpf"
		errors=$((errors + 1))
		log "ERROR: conversion failed: $base${awkerr:+: $awkerr}"
		[ "$base" = "general" ] && baseline_ok=0
	fi
done

# drop stale .opt files that have no source bat anymore
for o in "$STRAT"/*.opt; do
	[ -f "$o" ] || continue
	b=${o##*/}
	b=${b%.opt}
	if ! grep -qxF "$b" "$names_tmp"; then
		rm -f "$o"
		log "removed stale strategy: $b.opt"
	fi
done

LC_ALL=C sort -u "$names_tmp" > "$STRAT/list.txt"
rm -f "$names_tmp"

log "done: total=$total converted=$converted errors=$errors"
if [ "$converted" -gt 0 ] && [ "$errors" -eq 0 ] && [ "$baseline_ok" -eq 1 ]; then
	exit 0
fi
log "FAILED: converted=$converted errors=$errors baseline_ok=$baseline_ok"
exit 1
