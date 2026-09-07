#!/bin/sh
# fdy-sync.sh - sync the Flowseal "zapret-discord-youtube" distributive with
# upstream GitHub releases, for the zapret-openwrt package (remittor).
#
# Flow:
#   fetch release info (api.github.com, optional mirror prefix)
#   -> compare tag with /opt/zapret/fdy/current/version
#   -> download *.tar.gz to /tmp/fdy_dl.tar.gz
#   -> verify sha256 (digest from the GitHub API - mandatory gate)
#   -> unpack to /opt/zapret/fdy/staging and validate contents
#   -> copy user lists (*-user.txt) from current/lists
#   -> atomic swap current -> current.prev -> new current
#   -> run fdy-convert.sh (on failure: roll back the swap)
#   -> update state.json, optionally autotest / service restart
#
# Any failure before the swap leaves the old "current" untouched: the running
# service keeps working with the old files. New .bin files are picked up by
# nfqws only after the next service restart.
#
# Usage:
#   fdy-sync.sh --set-cron 'HH:MM'   install/replace the cron task
#   fdy-sync.sh --del-cron           remove the cron task
#   fdy-sync.sh --cron               cron entry point (respects uci enabled=1)
#   fdy-sync.sh --check              check only, prints: RESULT: (L|E|G) <version>
#   fdy-sync.sh --force              forced full sync (ignores uci enabled)

EXE_DIR=$(cd "$(dirname "$0")" 2>/dev/null || exit 1; pwd)

FDY_LIB="$EXE_DIR/fdy-lib.sh"
if [ ! -f "$FDY_LIB" ]; then
	echo "ERROR: file $FDY_LIB not found!"
	exit 1
fi
. "$FDY_LIB"

FDY_SYNC_RC=0

# -------------------------------------------------------------------------------------------------------

usage()
{
	cat <<EOF
Usage: $0 {--check|--force|--cron|--set-cron 'HH:MM'|--del-cron}
  --check           check for a new release (RESULT: (L|E|G) <version>)
  --force           forced full sync
  --cron            run by cron (skipped when uci fdy.sync.enabled != 1)
  --set-cron HH:MM  install the cron task at HH:MM
  --del-cron        remove the cron task
EOF
}

do_check()
{
	local cur cmp_res
	ensure_dirs || return 1
	fdy_uci_defaults
	fdy_fetch_release || fdy_fail "cannot fetch release info from GitHub"
	touch_state last_check "$( fdy_now_iso )" >/dev/null 2>&1
	cur=$( fdy_current_version )
	if [ "$cur" = "" ]; then
		echo "Installed version: none"
		echo "RESULT: (L) $FDY_REL_TAG"
		return 0
	fi
	echo "Installed version: $cur"
	cmp_res=$( fdy_ver_cmp "$cur" "$FDY_REL_TAG" )
	case "$cmp_res" in
		E)
			echo "RESULT: (E) $FDY_REL_TAG"
			;;
		L)
			echo "RESULT: (L) $FDY_REL_TAG"
			;;
		G)
			echo "RESULT: (G) $FDY_REL_TAG"
			;;
		*)
			echo "RESULT: (?) $FDY_REL_TAG"
			;;
	esac
	return 0
}

fdy_root_normalize()
{
	# the tarball usually contains a single top-level dir; flatten staging.tmp
	local tmp="$1" root entry n
	[ -f "$tmp/general.bat" ] && return 0
	root=$( find "$tmp" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1 )
	[ -n "$root" ] || return 1
	[ -f "$root/general.bat" ] || return 1
	n=$( find "$tmp" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l )
	[ "$n" = "1" ] || return 1
	log "flattening single top-level dir: $( basename "$root" )"
	for entry in "$root"/.[!.]* "$root"/..?* "$root"/*; do
		[ -e "$entry" ] || continue
		mv "$entry" "$tmp/" || return 1
	done
	rmdir "$root" || return 1
	[ -f "$tmp/general.bat" ] || return 1
	return 0
}

fdy_validate_staging()
{
	local d
	[ -f "$FDY_STAGING/general.bat" ] || { err "validation failed: $FDY_STAGING/general.bat not found"; return 1; }
	[ -d "$FDY_STAGING/bin" ] || { err "validation failed: $FDY_STAGING/bin not found"; return 1; }
	d=$( find "$FDY_STAGING/bin" -type f 2>/dev/null | head -n 1 )
	[ -n "$d" ] || { err "validation failed: $FDY_STAGING/bin is empty"; return 1; }
	[ -d "$FDY_STAGING/lists" ] || { err "validation failed: $FDY_STAGING/lists not found"; return 1; }
	d=$( find "$FDY_STAGING/lists" -type f 2>/dev/null | head -n 1 )
	[ -n "$d" ] || { err "validation failed: $FDY_STAGING/lists is empty"; return 1; }
	return 0
}

do_sync()
{
	local mirror cur cmp_res url digest fname fname_esc old_saved=0 rc
	ensure_dirs || exit 1
	fdy_uci_defaults

	mirror=$( uci_get_default mirror '' )
	if [ -n "$mirror" ]; then
		case "$mirror" in
			*/) ;;
			*) mirror="$mirror/" ;;
		esac
		FDY_MIRROR="$mirror"
		log "using mirror: $FDY_MIRROR"
	fi

	# 1. release info
	fdy_fetch_release || fdy_fail "cannot fetch release info from GitHub"
	log "latest release: $FDY_REL_TAG"
	touch_state last_check "$( fdy_now_iso )" >/dev/null 2>&1

	# 2. compare with installed
	cur=$( fdy_current_version )
	if [ "$cur" = "" ]; then
		log "no current version installed, performing initial install"
		cmp_res="L"
	else
		cmp_res=$( fdy_ver_cmp "$cur" "$FDY_REL_TAG" )
	fi
	if [ "$cmp_res" = "E" ]; then
		log "already up to date: $cur"
		echo "RESULT: (E) No update required! ($cur)"
		return 0
	fi
	if [ "$cmp_res" = "G" ]; then
		log "installed version $cur is newer than release $FDY_REL_TAG, nothing to do"
		echo "RESULT: (G) Installed version is newer! ($cur)"
		return 0
	fi
	log "update available: $cur -> $FDY_REL_TAG"

	# 3. download (any failure here keeps old current untouched)
	url="$FDY_REL_URL"
	if [ -n "$FDY_MIRROR" ]; then
		url="${FDY_MIRROR}${FDY_REL_URL}"
	fi
	rm -f "$FDY_DL_FILE"
	log "downloading: $url"
	curl -s -L --retry 5 --retry-delay 2 --retry-all-errors \
		--connect-timeout 10 --max-time 600 -o "$FDY_DL_FILE" "$url" 2>/dev/null
	if [ $? -ne 0 ] || [ ! -s "$FDY_DL_FILE" ]; then
		fdy_fail "download failed: $url"
	fi
	if [ "$( wc -c < "$FDY_DL_FILE" )" -lt 100000 ]; then
		fdy_fail "downloaded file is too small ($( wc -c < "$FDY_DL_FILE" ) bytes)"
	fi

	# 4. sha256 gate (mandatory)
	digest="${FDY_REL_DIGEST#sha256:}"
	if [ "$digest" = "" ] || [ "$digest" = "$FDY_REL_DIGEST" ]; then
		fdy_fail "no valid sha256 digest for release $FDY_REL_TAG"
	fi
	printf '%s  %s\n' "$digest" "$FDY_DL_FILE" > "$FDY_DL_SHA" || fdy_fail "cannot write sha256 file"
	if ! sha256sum -c "$FDY_DL_SHA" >/dev/null 2>&1; then
		fdy_fail "sha256 mismatch for $FDY_DL_FILE (expected $digest)"
	fi
	log "sha256 OK: $FDY_REL_TAG"

	# 5. unpack to staging.tmp -> flatten -> staging
	rm -rf "$FDY_STAGING_TMP" "$FDY_STAGING"
	mkdir -p "$FDY_STAGING_TMP" || fdy_fail "cannot create $FDY_STAGING_TMP"
	tar -zxf "$FDY_DL_FILE" -C "$FDY_STAGING_TMP" 2>/dev/null || fdy_fail "cannot extract $FDY_DL_FILE"
	if ! fdy_root_normalize "$FDY_STAGING_TMP"; then
		fdy_fail "unexpected archive layout (general.bat not found)"
	fi
	mv "$FDY_STAGING_TMP" "$FDY_STAGING" || fdy_fail "cannot rename staging dir"
	chmod 755 "$FDY_STAGING" 2>/dev/null

	# 6. validate staging
	if ! fdy_validate_staging; then
		fdy_fail "staging validation failed"
	fi

	# 7. preserve user lists
	if [ -d "$FDY_CURRENT/lists" ]; then
		for fname in "$FDY_CURRENT/lists/"*-user.txt; do
			[ -e "$fname" ] || continue
			fname_esc=$( basename "$fname" )
			cp -f "$fname" "$FDY_STAGING/lists/$fname_esc" || fdy_fail "cannot preserve user list: $fname_esc"
			log "user list preserved: $fname_esc"
		done
	fi

	# 8. version file
	printf '%s\n' "$FDY_REL_TAG" > "$FDY_STAGING/version" || fdy_fail "cannot write version file"
	chmod 644 "$FDY_STAGING/version" 2>/dev/null

	# 9. atomic swap
	if [ -d "$FDY_CURRENT" ]; then
		rm -rf "$FDY_CURRENT_PREV"
		if ! mv "$FDY_CURRENT" "$FDY_CURRENT_PREV"; then
			fdy_fail "cannot move current -> current.prev"
		fi
		old_saved=1
	fi
	if ! mv "$FDY_STAGING" "$FDY_CURRENT"; then
		if [ "$old_saved" = "1" ]; then
			mv "$FDY_CURRENT_PREV" "$FDY_CURRENT" 2>/dev/null
		fi
		fdy_fail "cannot move staging -> current"
	fi
	log "swap complete: now at $FDY_REL_TAG"

	# 10. convert strategies (on failure: roll back the swap)
	rc=0
	if [ -f "$FDY_CONVERT" ]; then
		log "running fdy-convert.sh ..."
		sh "$FDY_CONVERT" >> "$FDY_SYNC_LOG" 2>&1 || rc=1
	else
		err "fdy-convert.sh not found: $FDY_CONVERT"
		rc=1
	fi
	if [ "$rc" != "0" ]; then
		err "fdy-convert.sh failed, rolling back to previous version"
		rm -rf "$FDY_CURRENT"
		if [ "$old_saved" = "1" ]; then
			if ! mv "$FDY_CURRENT_PREV" "$FDY_CURRENT"; then
				err "ROLLBACK FAILED: previous version is in $FDY_CURRENT_PREV"
			fi
		fi
		touch_state status error >/dev/null 2>&1
		touch_state error "fdy-convert.sh failed, rolled back to $cur" >/dev/null 2>&1
		exit 1
	fi
	if [ -d "$FDY_CURRENT_PREV" ]; then
		rm -rf "$FDY_CURRENT_PREV"
	fi

	# 11. state
	touch_state version "$FDY_REL_TAG"
	touch_state synced_at "$( fdy_now_iso )"
	touch_state status ok
	touch_state error ""
	log "sync completed: $FDY_REL_TAG"
	echo "RESULT: OK ($FDY_REL_TAG)"

	# 12. optional autotest / restart (restart only when explicitly enabled and NOT autotest)
	if [ "$( uci_get_default autotest 0 )" = "1" ]; then
		if [ -f "$FDY_TEST" ]; then
			log "running fdy-test.sh ..."
			if sh "$FDY_TEST" >> "$FDY_SYNC_LOG" 2>&1; then
				log "autotest passed"
			else
				touch_state status error >/dev/null 2>&1
				touch_state error "autotest failed after sync $FDY_REL_TAG" >/dev/null 2>&1
				err "autotest failed"
				FDY_SYNC_RC=1
			fi
		else
			err "autotest enabled but fdy-test.sh not found: $FDY_TEST"
		fi
	elif [ "$( uci_get_default restart_after 0 )" = "1" ]; then
		if [ -x "$FDY_SERVICE_INITD" ]; then
			log "restarting zapret service ..."
			if "$FDY_SERVICE_INITD" restart >> "$FDY_SYNC_LOG" 2>&1; then
				log "zapret service restarted"
			else
				err "zapret service restart failed"
				FDY_SYNC_RC=1
			fi
		else
			err "restart_after enabled but $FDY_SERVICE_INITD not found"
		fi
	fi
	return 0
}

# -------------------------------------------------------------------------------------------------------

cron_valid_time()
{
	case "$1" in
		[0-9]:[0-5][0-9]|[0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;;
		*) return 1 ;;
	esac
}

cron_restart()
{
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1
	fi
}

do_set_cron()
{
	local ctime=$1 hour minute line
	cron_valid_time "$ctime" || die "invalid time '$ctime', expected HH:MM (i.e. 04:30)"
	hour="${ctime%%:*}"
	minute="${ctime#*:}"
	case "$hour" in [0-9]) hour="0$hour" ;; esac
	line="$minute $hour * * * $FDY_SYNC --cron >/dev/null 2>&1 $FDY_CRON_TAG"
	[ -f "$CRONTAB_FILE" ] || touch "$CRONTAB_FILE" || die "cannot create $CRONTAB_FILE"
	grep -v -F "$FDY_CRON_TAG" "$CRONTAB_FILE" > "$FDY_CRON_TMP" 2>/dev/null
	echo "$line" >> "$FDY_CRON_TMP"
	cat "$FDY_CRON_TMP" > "$CRONTAB_FILE" || die "cannot write $CRONTAB_FILE"
	rm -f "$FDY_CRON_TMP"
	cron_restart
	log "cron task installed: $line"
	echo "Cron task installed: $line"
	return 0
}

do_del_cron()
{
	if [ ! -f "$CRONTAB_FILE" ] || ! grep -q -F "$FDY_CRON_TAG" "$CRONTAB_FILE"; then
		echo "No fdy cron task found"
		return 0
	fi
	grep -v -F "$FDY_CRON_TAG" "$CRONTAB_FILE" > "$FDY_CRON_TMP" 2>/dev/null
	cat "$FDY_CRON_TMP" > "$CRONTAB_FILE" || die "cannot write $CRONTAB_FILE"
	rm -f "$FDY_CRON_TMP"
	cron_restart
	log "cron task removed"
	echo "Cron task removed"
	return 0
}

# -------------------------------------------------------------------------------------------------------

fdy_setup_traps

case "$1" in
	--check)
		do_check
		FDY_SYNC_RC=$?
		;;
	--force)
		do_sync
		[ $? -ne 0 ] && FDY_SYNC_RC=1
		;;
	--cron)
		ensure_dirs || exit 1
		fdy_uci_defaults
		if [ "$( uci_get_default enabled 0 )" != "1" ]; then
			log "sync is disabled (uci fdy.sync.enabled != 1), skipping"
			FDY_SYNC_RC=0
		else
			do_sync
			[ $? -ne 0 ] && FDY_SYNC_RC=1
		fi
		;;
	--set-cron)
		do_set_cron "$2"
		FDY_SYNC_RC=$?
		;;
	--del-cron)
		do_del_cron
		FDY_SYNC_RC=$?
		;;
	*)
		usage
		FDY_SYNC_RC=1
		;;
esac

exit $FDY_SYNC_RC
