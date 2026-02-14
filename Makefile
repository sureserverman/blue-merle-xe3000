include $(TOPDIR)/rules.mk

PKG_NAME:=blue-merle
PKG_VERSION:=3.0.0
PKG_RELEASE:=$(AUTORELEASE)

PKG_MAINTAINER:=Matthias <matthias@srlabs.de>
PKG_LICENSE:=BSD-3-Clause

include $(INCLUDE_DIR)/package.mk

define Package/blue-merle
	SECTION:=utils
	CATEGORY:=Utilities
	EXTRA_DEPENDS:=luci-base, coreutils-shred, python3-light
	TITLE:=Anonymity Enhancements for GL-XE3000 Puli AX
endef

define Package/blue-merle/description
	The blue-merle package enhances anonymity and reduces forensic
	traceability of the GL-XE3000 Puli AX 5G mobile router.
	Features: MAC/BSSID randomization on every boot, volatile client
	database, IMEI management (if supported by modem firmware).
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/blue-merle/install
	$(CP) ./files/* $(1)/
	$(INSTALL_BIN) ./files/etc/init.d/* $(1)/etc/init.d/
	$(INSTALL_BIN) ./files/etc/gl-switch.d/* $(1)/etc/gl-switch.d/
	$(INSTALL_BIN) ./files/usr/bin/* $(1)/usr/bin/
	$(INSTALL_BIN) ./files/usr/libexec/blue-merle $(1)/usr/libexec/blue-merle
	$(INSTALL_BIN) ./files/lib/blue-merle/imei_generate.py  $(1)/lib/blue-merle/imei_generate.py
endef

define Package/blue-merle/preinst
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0

	BM_DEVICE=""
	[ -f /tmp/sysinfo/model ] && BM_DEVICE=$$(cat /tmp/sysinfo/model)

	case "$$BM_DEVICE" in
		*GL-XE3000*)
			echo "Detected GL-XE3000 (Puli AX)"
			;;
		*)
			echo
			echo "This package is built for GL-XE3000 (Puli AX)."
			if [ -n "$$BM_DEVICE" ]; then
				echo "Your device: $$BM_DEVICE"
			fi
			echo -n "Install anyway? (y/N): "
			read answer
			case $$answer in
				y*|Y*) ;;
				*) exit 1;;
			esac
			;;
	esac

	# Stop gl_clients before we move its database to volatile storage
	[ -x /etc/init.d/gl_clients ] && /etc/init.d/gl_clients stop
endef

define Package/blue-merle/postinst
	#!/bin/sh
	# Configure switch button if the device has one
	if uci -q get switch-button.@main[0] >/dev/null 2>&1; then
		uci set switch-button.@main[0].func='sim'
		uci commit switch-button
	fi

	[ -x /etc/init.d/gl_clients ] && /etc/init.d/gl_clients start
endef

define Package/blue-merle/postrm
	#!/bin/sh
	if uci -q get switch-button.@main[0] >/dev/null 2>&1; then
		uci set switch-button.@main[0].func='tor'
		uci commit switch-button
	fi
endef
$(eval $(call BuildPackage,$(PKG_NAME)))
