include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-chongyoung
PKG_VERSION:=1.7
PKG_RELEASE:=1

PKG_MAINTAINER:=chizukuo <chizukuo@icloud.com>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-chongyoung
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for ChongYoung Campus Network
  PKGARCH:=all
  DEPENDS:=+curl
  PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_luci-app-chongyoung
endef

define Package/luci-app-chongyoung/conffiles
/etc/config/chongyoung
endef

define Package/luci-app-chongyoung/description
  LuCI support for ChongYoung Campus Network Auto Login.
endef

define Build/Compile
endef

define Package/luci-app-chongyoung/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/chongyoung $(1)/etc/config/chongyoung
	
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/chongyoung $(1)/etc/init.d/chongyoung
	
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/chongyoung.sh $(1)/usr/bin/chongyoung.sh
	
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-chongyoung.json $(1)/usr/share/rpcd/acl.d/luci-app-chongyoung.json
	
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/chongyoung.lua $(1)/usr/lib/lua/luci/controller/chongyoung.lua
	
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/chongyoung
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/chongyoung/general.js $(1)/www/luci-static/resources/view/chongyoung/general.js

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99_chongyoung $(1)/etc/uci-defaults/99_chongyoung
endef

$(eval $(call BuildPackage,luci-app-chongyoung))
