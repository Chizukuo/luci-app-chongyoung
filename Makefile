include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-feiyoung
PKG_VERSION:=2.2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=chizukuo <chizukuo@icloud.com>
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-feiyoung
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for FeiYoung Campus Network
  PKGARCH:=all
  DEPENDS:=+curl +kmod-macvlan
  PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_luci-app-feiyoung
endef

define Package/luci-app-feiyoung/conffiles
/etc/config/feiyoung
endef

define Package/luci-app-feiyoung/description
  LuCI support for FeiYoung Campus Network Auto Login.
endef

define Build/Compile
endef

define Package/luci-app-feiyoung/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/feiyoung $(1)/etc/config/feiyoung

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/feiyoung $(1)/etc/init.d/feiyoung

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/feiyoung.sh $(1)/usr/bin/feiyoung.sh

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-feiyoung.json $(1)/usr/share/rpcd/acl.d/luci-app-feiyoung.json

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-feiyoung.json $(1)/usr/share/luci/menu.d/luci-app-feiyoung.json

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/feiyoung.lua $(1)/usr/lib/lua/luci/controller/feiyoung.lua

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/feiyoung
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/feiyoung/general.js $(1)/www/luci-static/resources/view/feiyoung/general.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/status/include/10_feiyoung.js $(1)/www/luci-static/resources/view/status/include/10_feiyoung.js

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99_feiyoung $(1)/etc/uci-defaults/99_feiyoung
endef

$(eval $(call BuildPackage,luci-app-feiyoung))
