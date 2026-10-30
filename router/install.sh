#!/bin/sh
# Installs the Switchyard router plugin on OpenWrt. Run it on the router:
#   wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/router/install.sh | sh
BASE="https://raw.githubusercontent.com/soum91/switchyard/main/router"

say() { echo "switchyard: $*"; }
die() { echo "switchyard: $*" >&2; exit 1; }

pkg_add() {
	if command -v apk >/dev/null 2>&1; then
		apk update >/dev/null 2>&1
		apk add "$@"
	else
		opkg update >/dev/null 2>&1
		opkg install "$@"
	fi
}

# The plugin runs inside rpcd as ucode (LuCI already uses both).
if [ ! -f /usr/lib/rpcd/ucode.so ]; then
	say "adding rpcd-mod-ucode"
	pkg_add rpcd-mod-ucode ucode-mod-fs ucode-mod-uci || die "couldn't install rpcd-mod-ucode"
fi

# The apps talk to the router through uhttpd's /ubus endpoint (LuCI turns it on).
if [ ! -f /usr/lib/uhttpd_ubus.so ]; then
	say "adding uhttpd-mod-ubus"
	pkg_add uhttpd-mod-ubus || die "couldn't install uhttpd-mod-ubus"
fi
if [ -z "$(uci -q get uhttpd.main.ubus_prefix)" ]; then
	uci set uhttpd.main.ubus_prefix='/ubus'
	uci commit uhttpd
	/etc/init.d/uhttpd restart
fi

mkdir -p /usr/share/rpcd/ucode /usr/share/rpcd/acl.d
wget -qO /tmp/switchyard.uc "$BASE/switchyard" || die "download failed (plugin)"
wget -qO /tmp/switchyard.json "$BASE/switchyard.json" || die "download failed (permissions)"
grep -q "switchyard" /tmp/switchyard.uc || die "the plugin download looks wrong"
mv /tmp/switchyard.uc /usr/share/rpcd/ucode/switchyard
mv /tmp/switchyard.json /usr/share/rpcd/acl.d/switchyard.json

/etc/init.d/rpcd restart
sleep 2
if ubus call switchyard version >/dev/null 2>&1; then
	say "installed. Open Switchyard (or Keystone > Router) and sign in with your root password."
else
	say "installed, but rpcd didn't load it. Send this to Claude:"
	logread | grep -i -E "rpcd|ucode" | tail -n 15
	exit 1
fi
