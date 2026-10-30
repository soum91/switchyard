include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-lightsout
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=soum91

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-lightsout
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Lights Out: router LED schedule that survives reboots
  PKGARCH:=all
endef

define Package/luci-app-lightsout/description
  Turns the router's LEDs off at night on a schedule, with a page under System > Router lights.
  The schedule is re-applied at boot, when the clock syncs and every 5 minutes, so a reboot in
  the middle of the night doesn't bring the lights back.
endef

define Package/luci-app-lightsout/conffiles
/etc/config/lightsout
endef

define Build/Compile
endef

define Package/luci-app-lightsout/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/sbin $(1)/etc/hotplug.d/ntp $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_CONF) ./files/lightsout.config $(1)/etc/config/lightsout
	$(INSTALL_BIN) ./files/lightsout.init $(1)/etc/init.d/lightsout
	$(INSTALL_BIN) ./files/lightsout.sh $(1)/usr/sbin/lightsout
	$(INSTALL_DATA) ./files/lightsout.hotplug $(1)/etc/hotplug.d/ntp/90-lightsout
	$(INSTALL_BIN) ./files/lightsout.defaults $(1)/etc/uci-defaults/90-lightsout
	$(INSTALL_DATA) ./files/lightsout.js $(1)/www/luci-static/resources/view/lightsout.js
	$(INSTALL_DATA) ./files/menu.json $(1)/usr/share/luci/menu.d/luci-app-lightsout.json
	$(INSTALL_DATA) ./files/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-lightsout.json
endef

define Package/luci-app-lightsout/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
endef

define Package/luci-app-lightsout/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/sbin/lightsout uninstall
exit 0
endef

$(eval $(call BuildPackage,luci-app-lightsout))
