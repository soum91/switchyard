#!/bin/sh
# Junction: use several upstream connections at once and drop the ones that go bad.
#
#   junction run                 the daemon (started by /etc/init.d/junction)
#   junction status              JSON for the apps and LuCI
#   junction add RADIO SSID [KEY] [NAME] [ENC]   connect a radio to another source
#   junction remove IFACE        forget a source (and the Wi-Fi link if Junction made it)
#   junction cleanup             take all routing changes back out
#
# How it works: every source keeps its own routing table (100 + n) with a default route through it.
# New connections from the LAN get a connection mark picked by a hash of device + destination, so one
# device talking to one site always uses the same source (logins and streams don't get confused),
# while different devices and sites are spread over the sources by weight. The router's own traffic
# and anything unmarked follows the best source (metric 1 default in the main table).
# A source is dropped when pings through it fail, its loss gets too high, or its signal stays under
# the floor; it comes back after it has been good for a few rounds in a row.

. /lib/functions.sh

RUNDIR=/var/run/junction
STATUS=/tmp/junction.json
LOG=/tmp/junction.log
PIDFILE=/var/run/junction.pid
TBASE=100        # routing table per source: 101, 102, ...
PSRC=900         # ip rule priority for "from <source address>"
PMARK=1000       # ip rule priority for "fwmark <n>"
LANIFS='"br-lan", "br-syguest"'

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
	logger -t junction "$*"
	n=$(wc -l < "$LOG")
	[ "$n" -gt 300 ] && sed -i "1,$((n - 200))d" "$LOG"
}

# ---------------------------------------------------------------------------------------------
# config

N=0
add_uplink() {
	local iface name weight en man
	config_get iface "$1" iface
	[ -n "$iface" ] || return 0
	config_get_bool en "$1" enabled 1
	config_get name "$1" name "$iface"
	config_get weight "$1" weight auto
	config_get_bool man "$1" managed 0
	N=$((N + 1))
	eval "IF_$N=\$iface; NAME_$N=\$name; WCFG_$N=\$weight; EN_$N=\$en; SEC_$N=\$1; MAN_$N=\$man"
}

load_cfg() {
	N=0
	config_load junction
	config_get_bool ENABLED main enabled 1
	config_get MODE main mode balance
	config_get INTERVAL main interval 5
	config_get MIN_SIGNAL main min_signal -82
	config_get MAX_LOSS main max_loss 30
	config_get TARGETS main target '1.1.1.1 8.8.8.8 9.9.9.9'
	config_foreach add_uplink uplink
}

# ---------------------------------------------------------------------------------------------
# what each source looks like right now: sets UP DEV IP GW SIG RATE SSID

facts() {
	local j
	UP=0; DEV=; IP=; GW=; SIG=; RATE=; SSID=
	j=$(ifstatus "$1" 2>/dev/null) || return 0
	[ "$(echo "$j" | jsonfilter -e '@.up')" = true ] && UP=1
	DEV=$(echo "$j" | jsonfilter -e '@.l3_device')
	IP=$(echo "$j" | jsonfilter -e '@["ipv4-address"][0].address')
	GW=$(echo "$j" | jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' | head -n 1)
	[ -n "$GW" ] || GW=$(echo "$j" | jsonfilter -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | head -n 1)
	if [ -n "$DEV" ] && w=$(iwinfo "$DEV" info 2>/dev/null) && [ -n "$w" ]; then
		SIG=$(echo "$w" | sed -n 's/.*Signal: \(-\{0,1\}[0-9]*\) dBm.*/\1/p' | head -n 1)
		RATE=$(echo "$w" | sed -n 's/.*Bit Rate: \([0-9]*\).*/\1/p' | head -n 1)
		SSID=$(echo "$w" | sed -n 's/.*ESSID: "\(.*\)".*/\1/p' | head -n 1)
	fi
}

# ---------------------------------------------------------------------------------------------
# probing

ROUND=0
probe() {   # $1 = source address; sets OK (1/0) and RTT
	local count t out
	count=$(echo $TARGETS | wc -w)
	t=$(echo $TARGETS | cut -d' ' -f$(( (ROUND % count) + 1 )))
	out=$(ping -c 1 -W 1 -I "$1" "$t" 2>/dev/null)
	if echo "$out" | grep -q 'time='; then
		OK=1
		RTT=$(echo "$out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -n 1)
	else
		# one more target before calling it a failure, so one dead DNS server isn't a dead link
		t=$(echo $TARGETS | cut -d' ' -f$(( ((ROUND + 1) % count) + 1 )))
		out=$(ping -c 1 -W 1 -I "$1" "$t" 2>/dev/null)
		if echo "$out" | grep -q 'time='; then
			OK=1
			RTT=$(echo "$out" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -n 1)
		else
			OK=0; RTT=
		fi
	fi
}

loss_of() {   # history string of 1/0 -> percent lost
	local h=$1 len zeros
	len=${#h}
	[ "$len" -gt 0 ] || { echo 0; return; }
	zeros=$(echo "$h" | tr -cd 0 | wc -c)
	echo $(( zeros * 100 / len ))
}

# ---------------------------------------------------------------------------------------------
# one round: look at every source and decide which are usable

check() {
	local i iface en h ok fails oks low st loss reason w
	ROUND=$((ROUND + 1))
	i=1
	while [ "$i" -le "$N" ]; do
		eval "iface=\$IF_$i; en=\$EN_$i; h=\$H_$i; fails=\${F_$i:-0}; oks=\${O_$i:-0}; low=\${L_$i:-0}; st=\${ST_$i:-?}"
		facts "$iface"
		reason=
		if [ "$en" != 1 ]; then
			st=0; reason=off
		elif [ "$UP" != 1 ] || [ -z "$IP" ] || [ -z "$GW" ]; then
			st=0; reason=down; h=; oks=0; fails=0
			eval "man=\$MAN_$i; ds=\$DS_$i"
			if [ "$man" = 1 ]; then
				now=$(date +%s)
				[ -n "$ds" ] || { ds=$now; eval "DS_$i=\$now"; }
				if [ $((now - ds)) -ge "$GIVEUP" ]; then
					giveup "$i"
					en=0; reason="couldn't connect, turned off"
				else
					reason="connecting ($((now - ds)) s)"
				fi
			fi
		else
			eval "DS_$i="
			ensure_table "$i"
			probe "$IP"
			h=$(echo "$h$OK" | sed 's/.*\(..........\)$/\1/')
			if [ "$OK" = 1 ]; then oks=$((oks + 1)); fails=0; else fails=$((fails + 1)); oks=0; fi
			if [ -n "$SIG" ] && [ "$SIG" -lt "$MIN_SIGNAL" ]; then low=$((low + 1)); else low=0; fi
			loss=$(loss_of "$h")
			if [ "$st" = 1 ]; then
				if [ "$fails" -ge 3 ]; then st=0; reason="no internet"
				elif [ "$low" -ge 3 ]; then st=0; reason="weak signal ($SIG dBm)"
				elif [ "${#h}" -ge 5 ] && [ "$loss" -gt "$MAX_LOSS" ]; then st=0; reason="losing $loss% of packets"
				fi
			elif [ "$st" = "?" ]; then
				# first look after start: trust one good ping so a reboot doesn't wait 15 s
				if [ "$OK" = 1 ] && [ "$low" = 0 ]; then st=1; else st=0; reason="no internet"; fi
			else
				if [ "$oks" -ge 3 ] && [ "$low" = 0 ]; then
					st=1; h=111
				elif [ "$low" -gt 0 ]; then reason="weak signal ($SIG dBm)"
				else reason="no internet"
				fi
			fi
		fi
		eval "prev=\${ST_$i:-?}"
		if [ "$prev" != "$st" ] && [ "$prev" != "?" ]; then
			eval "nm=\$NAME_$i"
			if [ "$st" = 1 ]; then log "$nm is back"; else log "$nm dropped: ${reason:-down}"; fi
		fi
		[ "$st" = 1 ] || eval "R_$i=\$reason"
		[ "$st" = 1 ] && eval "R_$i="
		eval "EN_$i=\$en; H_$i=\$h; F_$i=\$fails; O_$i=\$oks; L_$i=\$low; ST_$i=\$st"
		eval "UP_$i=\$UP; DEV_$i=\$DEV; IP_$i=\$IP; GW_$i=\$GW; SIG_$i=\$SIG; RATE_$i=\$RATE; SSID_$i=\$SSID; RTT_$i=\$RTT"
		# weight: fixed, or "auto" = link rate (wired counts as 300) scaled down by loss
		eval "w=\$WCFG_$i"
		if [ "$w" = auto ] || [ -z "$w" ]; then
			# signal says more about what a link can carry than the bit rate, which drops when idle
			if [ -n "$SIG" ]; then
				w=$((SIG + 100))
				[ "$w" -gt 60 ] && w=60
				[ "$w" -lt 5 ] && w=5
			else
				w=60
			fi
			loss=$(loss_of "$h")
			w=$(( w * (100 - loss) / 100 ))
		fi
		[ "$w" -ge 1 ] 2>/dev/null || w=1
		eval "W_$i=\$w"
		i=$((i + 1))
	done
}

GIVEUP=90
# A radio that's trying to join a network it can't reach keeps its own Wi-Fi down while it waits,
# so a source Junction added that hasn't connected in 90 s is switched off (the app can turn it on again).
giveup() {
	local i=$1 iface sec ssid
	eval "iface=\$IF_$i; sec=\$SEC_$i"
	ssid=$(uci -q get "wireless.jc_$iface.ssid")
	uci -q set "wireless.jc_$iface.disabled=1"
	uci -q set "junction.$sec.enabled=0"
	uci -q commit wireless
	uci -q commit junction
	log "couldn't connect to ${ssid:-$iface} for $GIVEUP s (wrong password, out of range, or not on that radio's band); turned it off so your own Wi-Fi on that radio comes back"
	( wifi reload ) >/dev/null 2>&1 </dev/null &
}

# Each source's own table, so pings from its address (and its marked connections) always leave
# through it, even while it isn't in use.
ensure_table() {
	local i=$1 t ipv dev gw
	t=$((TBASE + i))
	eval "dev=\$DEV; gw=\$GW; ipv=\$IP"
	ip route replace default via "$gw" dev "$dev" onlink table "$t" 2>/dev/null
	eval "old=\$RULEIP_$i"
	if [ "$old" != "$ipv" ]; then
		while ip rule del pref $((PSRC + i)) 2>/dev/null; do :; done
		ip rule add from "$ipv" table "$t" pref $((PSRC + i))
		eval "RULEIP_$i=\$ipv"
	fi
	ip rule show 2>/dev/null | grep -q "^$((PMARK + i)):" || ip rule add fwmark "$i" table "$t" pref $((PMARK + i))
	[ -w "/proc/sys/net/ipv4/conf/$dev/rp_filter" ] && echo 2 > "/proc/sys/net/ipv4/conf/$dev/rp_filter"
}

# ---------------------------------------------------------------------------------------------
# apply the decision

APPLIED=
apply() {
	local i st w total sig best bestw healthy map lo hi share dev gw
	total=0; healthy=0; best=0; bestw=0
	i=1
	while [ "$i" -le "$N" ]; do
		eval "st=\$ST_$i; w=\$W_$i"
		if [ "$st" = 1 ]; then
			healthy=$((healthy + 1))
			total=$((total + w))
			if [ "$MODE" = failover ]; then
				[ "$best" = 0 ] && best=$i
			elif [ "$w" -gt "$bestw" ]; then
				best=$i; bestw=$w
			fi
		else
			eval "dev=\$DEV_$i"
			[ -n "$dev" ] || ip route flush table $((TBASE + i)) 2>/dev/null
		fi
		i=$((i + 1))
	done

	# shares in whole percent, bucketed to 10 so small rate changes don't reshuffle everything
	map=; lo=0; sig="$MODE"
	if [ "$MODE" = balance ] && [ "$healthy" -ge 2 ]; then
		i=1
		while [ "$i" -le "$N" ]; do
			eval "st=\$ST_$i; w=\$W_$i"
			share=0
			if [ "$st" = 1 ]; then
				share=$(( (w * 10 + total / 2) / total * 10 ))
				[ "$share" -ge 10 ] || share=10
			fi
			eval "SHARE_$i=\$share"
			i=$((i + 1))
		done
		# make the shares add up to 100 by giving the remainder to the best source
		sum=0; i=1
		while [ "$i" -le "$N" ]; do eval "sum=\$((sum + SHARE_$i))"; i=$((i + 1)); done
		eval "SHARE_$best=\$((SHARE_$best + 100 - sum))"
		i=1
		while [ "$i" -le "$N" ]; do
			eval "share=\$SHARE_$i"
			if [ "$share" -gt 0 ]; then
				hi=$((lo + share - 1))
				map="$map${map:+, }$lo-$hi : $i"
				lo=$((hi + 1))
			fi
			i=$((i + 1))
		done
		sig="$sig|$map"
	else
		i=1
		while [ "$i" -le "$N" ]; do
			share=0; [ "$i" = "$best" ] && share=100
			eval "SHARE_$i=\$share"
			i=$((i + 1))
		done
	fi
	ACTIVE=$best
	if [ "$best" != 0 ]; then eval "sig=\"\$sig|\$best|\$GW_$best|\$DEV_$best\""; fi

	# Re-asserted every round: the kernel drops these when a link bounces, and netifd won't put them back.
	if [ "$best" != 0 ]; then
		eval "gw=\$GW_$best; dev=\$DEV_$best"
		ip route replace default via "$gw" dev "$dev" onlink metric 1
	elif [ -n "$APPLIED" ]; then
		ip route del default metric 1 2>/dev/null
	fi
	if [ -n "$map" ]; then
		nft list table inet junction >/dev/null 2>&1 || APPLIED=
	fi

	[ "$sig" = "$APPLIED" ] && return 0

	if [ -n "$map" ]; then
		nft -f - <<EOF
table inet junction
delete table inet junction
table inet junction {
	chain pre {
		type filter hook prerouting priority mangle; policy accept;
		iifname != { $LANIFS } return
		meta nfproto != ipv4 return
		ip daddr { 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } return
		ct state new ct mark set jhash ip saddr . ip daddr mod 100 seed 0x4a43 map { $map }
		ct mark != 0 meta mark set ct mark
	}
}
EOF
	else
		nft delete table inet junction 2>/dev/null
	fi
	APPLIED=$sig
}

# ---------------------------------------------------------------------------------------------
# status

jstr() { printf '"%s"' "$(echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
jnum() { [ -n "$1" ] && echo "$1" || echo null; }

write_status() {
	local i out first iface st
	out="{\"enabled\":$ENABLED,\"mode\":$(jstr "$MODE"),\"active\":"
	if [ "${ACTIVE:-0}" != 0 ]; then eval "out=\"\$out\$(jstr \"\$IF_$ACTIVE\")\""; else out="${out}null"; fi
	out="$out,\"min_signal\":$MIN_SIGNAL,\"max_loss\":$MAX_LOSS,\"interval\":$INTERVAL,\"time\":$(date +%s),\"uplinks\":["
	first=1; i=1
	while [ "$i" -le "$N" ]; do
		[ "$first" = 1 ] || out="$out,"
		first=0
		eval "iface=\$IF_$i; st=\$ST_$i"
		eval "out=\"\$out{\\\"iface\\\":\$(jstr \"\$IF_$i\"),\\\"name\\\":\$(jstr \"\$NAME_$i\"),\\\"enabled\\\":\$EN_$i\""
		eval "out=\"\$out,\\\"up\\\":\${UP_$i:-0},\\\"healthy\\\":\$( [ \"\$ST_$i\" = 1 ] && echo true || echo false)\""
		eval "out=\"\$out,\\\"dev\\\":\$(jstr \"\$DEV_$i\"),\\\"ip\\\":\$(jstr \"\$IP_$i\"),\\\"gw\\\":\$(jstr \"\$GW_$i\"),\\\"ssid\\\":\$(jstr \"\$SSID_$i\")\""
		eval "out=\"\$out,\\\"signal\\\":\$(jnum \"\$SIG_$i\"),\\\"rate\\\":\$(jnum \"\$RATE_$i\"),\\\"rtt\\\":\$(jnum \"\$RTT_$i\"),\\\"loss\\\":\$(loss_of \"\$H_$i\")\""
		eval "out=\"\$out,\\\"weight\\\":\$(jstr \"\$WCFG_$i\"),\\\"share\\\":\${SHARE_$i:-0},\\\"reason\\\":\$(jstr \"\$R_$i\")}\""
		i=$((i + 1))
	done
	echo "$out],\"log\":$(wc -l < "$LOG" 2>/dev/null || echo 0)}" > "$STATUS.tmp"
	mv "$STATUS.tmp" "$STATUS"
}

# ---------------------------------------------------------------------------------------------

cleanup() {
	local i
	nft delete table inet junction 2>/dev/null
	ip route del default metric 1 2>/dev/null
	i=1
	while [ "$i" -le 8 ]; do
		while ip rule del pref $((PSRC + i)) 2>/dev/null; do :; done
		while ip rule del pref $((PMARK + i)) 2>/dev/null; do :; done
		ip route flush table $((TBASE + i)) 2>/dev/null
		i=$((i + 1))
	done
	rm -f "$STATUS" "$PIDFILE"
}

run() {
	load_cfg
	[ "$ENABLED" = 1 ] || { cleanup; exit 0; }
	echo $$ > "$PIDFILE"
	trap 'cleanup; exit 0' TERM INT
	trap 'kill $SLEEPER 2>/dev/null' USR1
	log "started ($MODE, $N sources)"
	while :; do
		check
		apply
		write_status
		# a source that just failed gets rechecked every second until it's decided either way
		wait_for=$INTERVAL
		i=1
		while [ "$i" -le "$N" ]; do
			eval "f=\${F_$i:-0}; o=\${O_$i:-0}; st=\${ST_$i}"
			{ [ "$st" = 1 ] && [ "$f" -gt 0 ]; } || { [ "$st" = 0 ] && [ "$o" -gt 0 ]; } && wait_for=1
			i=$((i + 1))
		done
		sleep "$wait_for" &
		SLEEPER=$!
		wait $SLEEPER 2>/dev/null
	done
}

# ---------------------------------------------------------------------------------------------
# adding and removing sources

radio_busy() {   # prints the SSID of an existing upstream link on that radio
	local s dev mode dis
	for s in $(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-iface$/\1/p"); do
		dev=$(uci -q get "wireless.$s.device"); mode=$(uci -q get "wireless.$s.mode"); dis=$(uci -q get "wireless.$s.disabled")
		[ "$dev" = "$1" ] && [ "$mode" = sta ] && [ "$dis" != 1 ] && { uci -q get "wireless.$s.ssid"; return 0; }
	done
	return 1
}

wan_zone() {
	local z nets
	for z in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		nets=" $(uci -q get "firewall.$z.network") "
		case "$nets" in *" wwan "*|*" wan "*) echo "$z"; return 0 ;; esac
	done
	for z in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=zone$/\1/p'); do
		[ "$(uci -q get "firewall.$z.name")" = wan ] && { echo "$z"; return 0; }
	done
}

add() {
	local radio=$1 ssid=$2 key=$3 name=$4 enc=$5 n iface sec zone busy
	[ -n "$radio" ] && [ -n "$ssid" ] || { echo '{"error":"Pick a radio and a network."}'; return 1; }
	[ "$(uci -q get "wireless.$radio")" = wifi-device ] || { echo '{"error":"No such radio."}'; return 1; }
	if busy=$(radio_busy "$radio"); then
		printf '{"error":"%s already connects to %s. Each radio can hold one source; remove that one first or use the other radio."}\n' "$radio" "$busy"
		return 1
	fi
	n=2
	while [ -n "$(uci -q get "network.wwan$n")" ]; do n=$((n + 1)); done
	iface=wwan$n
	[ -n "$enc" ] || { [ -n "$key" ] && enc=psk2 || enc=none; }
	[ -n "$name" ] || name=$ssid

	# one uci call per value, quoted: names like "WE GUCCI" have spaces
	uci set "network.$iface=interface"
	uci set "network.$iface.proto=dhcp"
	uci set "network.$iface.metric=$((10 * n))"
	uci set "wireless.jc_$iface=wifi-iface"
	uci set "wireless.jc_$iface.device=$radio"
	uci set "wireless.jc_$iface.mode=sta"
	uci set "wireless.jc_$iface.network=$iface"
	uci set "wireless.jc_$iface.ssid=$ssid"
	uci set "wireless.jc_$iface.encryption=$enc"
	[ -n "$key" ] && uci set "wireless.jc_$iface.key=$key"
	zone=$(wan_zone)
	[ -n "$zone" ] && uci add_list "firewall.$zone.network=$iface"
	sec=$(uci add junction uplink)
	uci set "junction.$sec.iface=$iface"
	uci set "junction.$sec.name=$name"
	uci set "junction.$sec.managed=1"
	uci commit network; uci commit wireless; uci commit firewall; uci commit junction
	log "added $name on $radio ($iface)"
	( sleep 1; /etc/init.d/network reload; /etc/init.d/firewall reload; wifi reload; sleep 2; /etc/init.d/junction restart ) >/dev/null 2>&1 </dev/null &
	printf '{"ok":true,"iface":"%s"}\n' "$iface"
}

remove() {
	local iface=$1 s managed zone found=
	for s in $(uci -q show junction | sed -n 's/^junction\.\([^.=]*\)=uplink$/\1/p'); do
		[ "$(uci -q get "junction.$s.iface")" = "$iface" ] || continue
		found=1
		managed=$(uci -q get "junction.$s.managed")
		uci delete "junction.$s"
	done
	[ -n "$found" ] || { echo '{"error":"That source isn'"'"'t in Junction."}'; return 1; }
	if [ "$managed" = 1 ]; then
		uci -q delete "wireless.jc_$iface"
		uci -q delete "network.$iface"
		zone=$(wan_zone)
		[ -n "$zone" ] && uci -q del_list "firewall.$zone.network=$iface"
		uci commit wireless; uci commit network; uci commit firewall
	fi
	uci commit junction
	log "removed $iface"
	( sleep 1; [ "$managed" = 1 ] && { /etc/init.d/network reload; /etc/init.d/firewall reload; wifi reload; }; /etc/init.d/junction restart ) >/dev/null 2>&1 </dev/null &
	echo '{"ok":true}'
}

[ -n "$JUNCTION_LIB" ] && . "$JUNCTION_LIB"   # test hooks only

case "$1" in
	run) run ;;
	status) cat "$STATUS" 2>/dev/null || echo '{"enabled":0,"uplinks":[]}' ;;
	add) shift; add "$@" ;;
	remove) remove "$2" ;;
	cleanup) cleanup ;;
	check) [ -f "$PIDFILE" ] && kill -USR1 "$(cat "$PIDFILE")" 2>/dev/null ;;
	*) echo "usage: junction run|status|add RADIO SSID [KEY] [NAME] [ENC]|remove IFACE|cleanup" >&2; exit 1 ;;
esac
