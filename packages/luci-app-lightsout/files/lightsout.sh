#!/bin/sh
# Lights Out: router LED schedule.
#   lightsout apply     set the lights to what the schedule says now (cron, boot, clock sync)
#   lightsout on|off    switch now; sticks until the next scheduled change
#   lightsout status    one line of key=value pairs
#   lightsout cron      rewrite this package's crontab lines from the config
. /lib/functions.sh

LEDS=/sys/class/leds
OVERRIDE=/tmp/lightsout.override
SAVED=/tmp/lightsout.saved
CRON=/etc/crontabs/root

config_load lightsout
config_get_bool enabled main enabled 0
config_get off_at main off '23:00'
config_get on_at main on '07:00'
config_get chosen main led ''

led_list() {
	if [ -n "$chosen" ]; then
		for l in $chosen; do [ -d "$LEDS/$l" ] && echo "$l"; done
	else
		for d in "$LEDS"/*; do
			l=${d##*/}
			case "$l" in mt76*|'*') ;; *) echo "$l" ;; esac
		done
	fi
}

trigger() {
	sed -n 's/.*\[\(.*\)\].*/\1/p' "$LEDS/$1/trigger" 2>/dev/null
}

# "07:05" -> 425
minutes() {
	h=$(echo "${1%%:*}" | sed 's/^0*//'); m=$(echo "${1##*:}" | sed 's/^0*//')
	echo $(( ${h:-0} * 60 + ${m:-0} ))
}

now_minutes() {
	minutes "$(date +%H:%M)"
}

# 1 when the schedule says the lights should be off right now
night() {
	[ "$enabled" = 1 ] || { echo 0; return; }
	o=$(minutes "$off_at"); n=$(minutes "$on_at"); t=$(now_minutes)
	if [ "$o" -lt "$n" ]; then
		[ "$t" -ge "$o" ] && [ "$t" -lt "$n" ] && { echo 1; return; }
	elif [ "$o" -gt "$n" ]; then
		{ [ "$t" -ge "$o" ] || [ "$t" -lt "$n" ]; } && { echo 1; return; }
	fi
	echo 0
}

lights_off() {
	for l in $(led_list); do
		[ "$(trigger "$l")" = none ] && continue
		return 1
	done
	return 0
}

set_lights() {
	if [ "$1" = off ]; then
		for l in $(led_list); do
			t=$(trigger "$l")
			if [ -n "$t" ] && [ "$t" != none ] && ! grep -q "^$l " "$SAVED" 2>/dev/null; then
				echo "$l $t" >> "$SAVED"
			fi
			echo none > "$LEDS/$l/trigger"
			echo 0 > "$LEDS/$l/brightness"
		done
	else
		for l in $(led_list); do
			[ "$(trigger "$l")" = none ] || continue
			t=$(sed -n "s/^$l //p" "$SAVED" 2>/dev/null | head -n 1)
			echo "${t:-default-on}" > "$LEDS/$l/trigger"
		done
		rm -f "$SAVED"
	fi
}

desired() {
	nt=$(night)
	if [ -f "$OVERRIDE" ]; then
		read -r state when < "$OVERRIDE"
		# A manual switch holds until the schedule itself changes over.
		if [ "$when" = "$nt" ]; then echo "$state"; return; fi
		rm -f "$OVERRIDE"
	fi
	[ "$nt" = 1 ] && echo off || echo on
}

apply() {
	want=$(desired)
	if [ "$want" = off ]; then
		lights_off || set_lights off
	else
		lights_off && set_lights on
	fi
	return 0
}

manual() {
	echo "$1 $(night)" > "$OVERRIDE"
	set_lights "$1"
}

write_cron() {
	touch "$CRON"
	tmp=$(mktemp)
	grep -v 'lightsout' "$CRON" | grep -v '/sys/class/leds' | grep -v 'switchyard leds' > "$tmp"
	if [ "$enabled" = 1 ]; then
		oh=$(minutes "$off_at"); nh=$(minutes "$on_at")
		echo "$((oh % 60)) $((oh / 60)) * * * /usr/sbin/lightsout apply" >> "$tmp"
		echo "$((nh % 60)) $((nh / 60)) * * * /usr/sbin/lightsout apply" >> "$tmp"
		echo "*/5 * * * * /usr/sbin/lightsout apply" >> "$tmp"
	fi
	if ! cmp -s "$tmp" "$CRON"; then
		cat "$tmp" > "$CRON"
		/etc/init.d/cron restart >/dev/null 2>&1
	fi
	rm -f "$tmp"
}

case "$1" in
	apply) apply ;;
	on|off) manual "$1" ;;
	toggle) if lights_off; then manual on; else manual off; fi ;;
	cron) write_cron ;;
	status)
		lights_off && state=off || state=on
		ovr=0; [ -f "$OVERRIDE" ] && ovr=1
		echo "lights=$state enabled=$enabled off=$off_at on=$on_at night=$(night) override=$ovr leds=$(led_list | wc -l) time=$(date +%H:%M)"
		;;
	uninstall)
		enabled=0
		write_cron
		lights_off && set_lights on
		rm -f "$OVERRIDE"
		;;
	*)
		echo "usage: lightsout apply|on|off|toggle|status|cron" >&2
		exit 1
		;;
esac
