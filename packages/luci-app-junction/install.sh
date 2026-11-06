#!/bin/sh
# Installs Junction (several internet sources at once + LuCI page). Run on the router:
#   wget -qO- https://raw.githubusercontent.com/soum91/switchyard/main/packages/luci-app-junction/install.sh | sh
REPO=soum91/switchyard
RAW="https://raw.githubusercontent.com/$REPO/main/packages/luci-app-junction/files"
say() { echo "junction: $*"; }

url=$(wget -qO- "https://api.github.com/repos/$REPO/releases?per_page=40" 2>/dev/null \
	| jsonfilter -e '@[*].assets[*].browser_download_url' 2>/dev/null | grep 'luci-app-junction.*\.apk$' | head -n 1)

if [ -n "$url" ] && command -v apk >/dev/null 2>&1 && wget -qO /tmp/luci-app-junction.apk "$url"; then
	say "installing ${url##*/}"
	if apk add --allow-untrusted /tmp/luci-app-junction.apk; then
		rm -f /tmp/luci-app-junction.apk
		say "done. LuCI: Network > Junction. Shell: junction status"
		exit 0
	fi
	say "the package didn't install, copying the files instead"
fi

# No package (or no apk): put the same files in place by hand.
set -e
get() { wget -qO "$2" "$RAW/$1"; }
mkdir -p /www/luci-static/resources/view /usr/share/luci/menu.d /usr/share/rpcd/acl.d /etc/hotplug.d/iface
[ -f /etc/config/junction ] || get junction.config /etc/config/junction
get junction.sh /usr/sbin/junction && chmod 755 /usr/sbin/junction
get junction.init /etc/init.d/junction && chmod 755 /etc/init.d/junction
get junction.hotplug /etc/hotplug.d/iface/95-junction
get junction.js /www/luci-static/resources/view/junction.js
get menu.json /usr/share/luci/menu.d/luci-app-junction.json
get acl.json /usr/share/rpcd/acl.d/luci-app-junction.json
get junction.defaults /tmp/junction.defaults && sh /tmp/junction.defaults && rm -f /tmp/junction.defaults
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload
say "done (files copied). LuCI: Network > Junction. Shell: junction status"
