#!/bin/sh
# Remote access for the OpenWrt router (and everything on its network) through Tailscale.
# Run it on the router:
#   wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/router/tailscale.sh | sh
# Safe to run again: it only adds what's missing.

say() { echo "tailscale-setup: $*"; }
die() { echo "tailscale-setup: $*" >&2; exit 1; }

# 1. Room and package
FREE=$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')
if ! command -v tailscale >/dev/null 2>&1; then
	[ -n "$FREE" ] && [ "$FREE" -lt 30000 ] && die "only $((FREE / 1024)) MB free on the router; Tailscale needs about 30 MB"
	say "installing tailscale"
	apk update >/dev/null 2>&1
	# The package's install script runs "tailscaled --cleanup", which can exit non-zero on OpenWrt
	# (no iptables) and makes apk report "1 error" even though everything installed.
	apk add tailscale
	command -v tailscale >/dev/null 2>&1 || die "couldn't install tailscale"
fi
uci -q get tailscale.settings >/dev/null && uci set tailscale.settings.fw_mode='nftables' && uci commit tailscale

# 2. Network interface and firewall zone (so phones on Tailscale can reach the LAN)
if [ -z "$(uci -q get network.tailscale)" ]; then
	say "adding the tailscale interface"
	uci set network.tailscale=interface
	uci set network.tailscale.proto='none'
	uci set network.tailscale.device='tailscale0'
	uci commit network
	/etc/init.d/network reload
fi
if ! uci show firewall | grep -q "name='tailscale'"; then
	say "adding the tailscale firewall zone"
	uci add firewall zone >/dev/null
	uci set firewall.@zone[-1].name='tailscale'
	uci set firewall.@zone[-1].input='ACCEPT'
	uci set firewall.@zone[-1].output='ACCEPT'
	uci set firewall.@zone[-1].forward='ACCEPT'
	uci add_list firewall.@zone[-1].network='tailscale'
	uci add firewall forwarding >/dev/null
	uci set firewall.@forwarding[-1].src='tailscale'
	uci set firewall.@forwarding[-1].dest='lan'
	uci add firewall forwarding >/dev/null
	uci set firewall.@forwarding[-1].src='lan'
	uci set firewall.@forwarding[-1].dest='tailscale'
	uci commit firewall
	/etc/init.d/firewall restart >/dev/null 2>&1
fi

# 3. The LAN to share (e.g. 192.168.1.0/24)
IP=$(uci -q get network.lan.ipaddr)
MASK=$(uci -q get network.lan.netmask)
case "$IP" in */*) MASK=${IP#*/}; IP=${IP%/*} ;; esac
[ -n "$IP" ] || die "couldn't read the LAN address"
eval "$(/bin/ipcalc.sh "$IP" "${MASK:-255.255.255.0}")"
ROUTE="$NETWORK/$PREFIX"

# 4. Start it and sign in
/etc/init.d/tailscale enable
/etc/init.d/tailscale restart >/dev/null 2>&1
sleep 4

if tailscale status >/dev/null 2>&1; then
	tailscale set --advertise-routes="$ROUTE" --accept-dns=false
	say "already signed in; sharing $ROUTE"
else
	rm -f /tmp/ts-up.log
	( tailscale up --advertise-routes="$ROUTE" --accept-dns=false >/tmp/ts-up.log 2>&1 & )
	i=0
	while [ $i -lt 30 ] && ! grep -q "https://" /tmp/ts-up.log 2>/dev/null; do sleep 1; i=$((i + 1)); done
	URL=$(grep -o "https://[^ ]*" /tmp/ts-up.log | head -1)
	[ -n "$URL" ] || die "tailscale didn't give a sign-in link; output: $(cat /tmp/ts-up.log)"
	echo
	say "open this link on your phone and sign in:"
	echo
	echo "    $URL"
	echo
fi

say "then at login.tailscale.com > Machines > this router > ... :"
say "  Edit route settings > turn on $ROUTE"
say "  Disable key expiry"
say "free space left: $(df -h /overlay | awk 'NR==2 {print $4}')"
