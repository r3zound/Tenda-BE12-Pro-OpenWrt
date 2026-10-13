# =============================================================================
# tenda-preset — Tenda BE12 Pro 预置配置包
# -----------------------------------------------------------------------------
# 把本仓库 files/ 下的预置内容打进固件。
#
# ⚠️ 为什么要做成包：
#    OpenWrt **没有** FILES_DIR 这个自定义 rootfs 注入机制
#    （include/target.mk 里的 GENERIC_FILES_DIR 是 target 自己的 files 目录）。
#    想往镜像里塞文件，正规做法就是做一个包。
#    早期版本以为 build.sh 里的「FILES_DIR 注入」有效，实际什么也没接上 ——
#    编译全绿、体积守卫也过，事后扫 squashfs 才发现预置文件一个都不在固件里。
#
# ⚠️ 为什么只直接放 /etc/config/network，其余走 uci-defaults 的 uci batch：
#    apk 严格维护文件归属。/etc/config/dhcp 属于 dnsmasq、
#    /etc/config/dropbear 属于 dropbear、/etc/config/firewall 属于 firewall4，
#    别的包直接覆盖会报
#        ERROR: trying to overwrite etc/config/dhcp owned by dnsmasq
#    然后 package/install 整个失败，固件根本产不出来（Run #9 栽在这）。
#
#    /etc/config/network 没有任何包声明归属（netifd 也不带这个文件），
#    所以可以安全地作为普通文件随包安装。
#
#    dhcp / firewall / dropbear / system 四项改由
#    /etc/uci-defaults/99-tenda-custom 在首次开机时用 uci batch 写入。
#    这也是 OpenWrt 官方发默认配置的正统做法，不会有归属冲突。
#
# ⚠️ ./files/ 必须随包一起挂进来。install 规则靠它取文件。
#    build.sh / build.yml 里**不要** rm -rf files。
# =============================================================================

include $(TOPDIR)/rules.mk

PKG_NAME:=tenda-preset
PKG_VERSION:=1.1.0
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
  Tenda BE12 Pro 的预置配置：
    · /etc/config/network —— 192.168.100.254 网段、双 WAN 接口划分
      （eth2=电信 WAN1，lan3=移动 WAN2），是双 WAN 方案的地基
    · /etc/uci-defaults/99-tenda-custom —— 首次开机切阿里云软件源，
      并用 uci batch 写入 dhcp / firewall / dropbear / system
    · /usr/lib/tenda/install-mwan3.sh —— mwan3（nft 版）安装助手
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
	true
endef

define Build/Compile
	true
endef

define Package/tenda-preset/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/usr/lib/tenda
	$(CP) ./files/etc/config/network         $(1)/etc/config/
	$(CP) ./files/etc/config/wireless        $(1)/etc/config/
	$(CP) ./files/etc/uci-defaults/*          $(1)/etc/uci-defaults/
	$(CP) ./files/usr/lib/tenda/*             $(1)/usr/lib/tenda/
	@chmod 0755 $(1)/etc/uci-defaults/99-tenda-custom
	@chmod 0755 $(1)/usr/lib/tenda/install-mwan3.sh
endef

# ⚠️ 这里只列 network 和 wireless —— 这两者**都没有任何已安装包声明归属**。
#    （2026-10-13 解包固件后逐个查 apk 数据库核实：
#      network 归 tenda-preset 自己；wireless **无归属**；
#      而 dhcp / dropbear / firewall / luci 分别归
#      dnsmasq / dropbear / firewall4 / luci-base。
#      有归属的那些一旦在这里声明，apk 会报
#      "trying to overwrite ... owned by X"，package/install 整体失败、
#      固件直接产不出来（Run #9 实测）。它们改由 99-tenda-custom 的
#      uci batch 写入 —— 那是普通文件写入，不走包归属检查。）
#
# ⚠️ wireless 为什么必须预置进固件、不能只靠首启 uci set（坑 10）：
#    /etc/config/wireless 默认**不在 rootfs 里**，它由 /sbin/wifi config
#    在运行时生成。配置缺失时 `uci set wireless.default_radio0.disabled='1'`
#    会造出段类型错误的伪段（netifd / 生成器都不认），随后被整个洗掉 ——
#    现象是「配了 WiFi 却没生效」，设备以无密码开放网络上线。
#    所以必须把带正确段类型（wifi-device / wifi-iface）+ option path 的
#    完整配置随固件下发。verify-firmware.sh 会解包固件回查这一条。
#
# ⚠️ 2026-10-13 修：此前这里**漏了 wireless**。文件在
#    files/etc/config/ 里躺着却永远进不了固件，导致 Run #23/#24 的
#    「固件内容抽查」报「固件里没有 /etc/config/wireless」。
#    同一 bug 两个分支都有（main 与 immortalwrt-25.12）。
define Package/tenda-preset/conffiles
/etc/config/network
/etc/config/wireless
endef

$(eval $(call BuildPackage,tenda-preset))
