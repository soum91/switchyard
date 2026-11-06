include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-junction
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=soum91

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-junction
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Junction: use several internet sources at once
  PKGARCH:=all
endef

define Package/luci-app-junction/description
  Spreads connections over several upstream connections (one per radio, or wired WAN), keeping each
  device-to-site pair on one source, and drops a source when its internet dies, its loss climbs or
  its signal gets too weak. Page under Network > Junction.
endef

define Package/luci-app-junction/conffiles
/etc/config/junction
endef

define Build/Compile
endef

define Package/luci-app-junction/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/sbin $(1)/etc/hotplug.d/iface $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_CONF) ./files/junction.config $(1)/etc/config/junction
	$(INSTALL_BIN) ./files/junction.init $(1)/etc/init.d/junction
	$(INSTALL_BIN) ./files/junction.sh $(1)/usr/sbin/junction
	$(INSTALL_DATA) ./files/junction.hotplug $(1)/etc/hotplug.d/iface/95-junction
	$(INSTALL_BIN) ./files/junction.defaults $(1)/etc/uci-defaults/90-junction
	$(INSTALL_DATA) ./files/junction.js $(1)/www/luci-static/resources/view/junction.js
	$(INSTALL_DATA) ./files/menu.json $(1)/usr/share/luci/menu.d/luci-app-junction.json
	$(INSTALL_DATA) ./files/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-junction.json
endef

define Package/luci-app-junction/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
endef

define Package/luci-app-junction/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/junction stop 2>/dev/null
/etc/init.d/junction disable 2>/dev/null
/usr/sbin/junction cleanup
exit 0
endef

$(eval $(call BuildPackage,luci-app-junction))
