# =============================================================================
# tenda-preset — Tenda BE12 Pro 预置配置包
# -----------------------------------------------------------------------------
# 把本仓库 files/ 下的预置文件（网络、DHCP、防火墙、首次启动脚本、mwan3
# 安装助手）打进固件。
#
# ⚠️ 为什么必须做成包，而不是直接往源码树里塞文件：
#    OpenWrt **没有** FILES_DIR 这个自定义 rootfs 注入机制
#    （include/target.mk 里的 GENERIC_FILES_DIR 是 target 自己的 files 目录，
#      完全不是一回事）。想往镜像里塞文件，正规做法就是做一个包。
#
#    踩过的坑：早期版本以为 build.sh 里的「FILES_DIR 注入」有效，
#    实际什么也没接上 —— 编译全绿、体积守卫也过，事后扫 squashfs 才发现
#    /etc/config/network、/etc/uci-defaults/99-tenda-custom 全都不在固件里。
#    刷完机是官方默认的 192.168.1.1，双 WAN 预置配置、mwan3 安装脚本、
#    阿里云软件源切换全都没有。
# =============================================================================

include $(TOPDIR)/rules.mk

PKG_NAME:=tenda-preset
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0

PKG_MAINTAINER:=Tenda BE12 Pro OpenWrt
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/tenda-preset
  SECTION:=base
  CATEGORY:=base
  TITLE:=Tenda BE12 Pro 预置配置（双 WAN / 预置网段 / mwan3 助手）
  DEPENDS:=+luci
endef

define Package/tenda-preset/description
  Tenda BE12 Pro 的预置配置：192.168.100.254 网段、双 WAN 接口划分
  （eth2=电信 WAN1，lan3=移动 WAN2）、DHCP 池、首次启动脚本
  （切阿里云源）、以及 mwan3（nft 版）安装助手。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/tenda-preset/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/lib/tenda
	$(CP) ./files/etc/config/*  $(1)/etc/config/
	$(CP) ./files/etc/uci-defaults/*  $(1)/etc/uci-defaults/
	$(CP) ./files/usr/lib/tenda/*  $(1)/usr/lib/tenda/
	@chmod 0755 $(1)/etc/uci-defaults/99-tenda-custom
	@chmod 0755 $(1)/usr/lib/tenda/install-mwan3.sh
endef

# /etc/config/* 是 uci 配置，刷机后 sysupgrade 也会保留，属于 conffiles
define Package/tenda-preset/conffiles
/etc/config/dhcp
/etc/config/dropbear
/etc/config/firewall
/etc/config/network
/etc/config/system
endef

$(eval $(call BuildPackage,tenda-preset))
