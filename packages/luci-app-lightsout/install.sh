#!/bin/sh
# Installs Lights Out (router LED schedule + LuCI page). Run on the router:
#   wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/packages/luci-app-lightsout/install.sh | sh
REPO=soum91/switchyard
RAW="https://raw.githubusercontent.com/$REPO/main/packages/luci-app-lightsout/files"
say() { echo "lightsout: $*"; }

url=$(wget -qO- "https://api.github.com/repos/$REPO/releases?per_page=40" 2>/dev/null \
	| jsonfilter -e '@[*].assets[*].browser_download_url' 2>/dev/null | grep 'luci-app-lightsout.*\.apk$' | head -n 1)

if [ -n "$url" ] && command -v apk >/dev/null 2>&1 && wget -qO /tmp/luci-app-lightsout.apk "$url"; then
	say "installing ${url##*/}"
	if apk add --allow-untrusted /tmp/luci-app-lightsout.apk; then
		rm -f /tmp/luci-app-lightsout.apk
		say "done. LuCI: System > Router lights. Shell: lightsout status"
		exit 0
	fi
	say "the package didn't install, copying the files instead"
fi

# No package (or no apk): put the same files in place by hand.
set -e
get() { wget -qO "$2" "$RAW/$1"; }
mkdir -p /www/luci-static/resources/view /usr/share/luci/menu.d /usr/share/rpcd/acl.d /etc/hotplug.d/ntp
[ -f /etc/config/lightsout ] || get lightsout.config /etc/config/lightsout
get lightsout.sh /usr/sbin/lightsout && chmod 755 /usr/sbin/lightsout
get lightsout.init /etc/init.d/lightsout && chmod 755 /etc/init.d/lightsout
get lightsout.hotplug /etc/hotplug.d/ntp/90-lightsout
get lightsout.js /www/luci-static/resources/view/lightsout.js
get menu.json /usr/share/luci/menu.d/luci-app-lightsout.json
get acl.json /usr/share/rpcd/acl.d/luci-app-lightsout.json
get lightsout.defaults /tmp/lightsout.defaults && sh /tmp/lightsout.defaults && rm -f /tmp/lightsout.defaults
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload
say "done (files copied). LuCI: System > Router lights. Shell: lightsout status"
