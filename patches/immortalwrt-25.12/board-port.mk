# =============================================================================
# board-port.mk — Tenda BE12 Pro 板级移植块
# -----------------------------------------------------------------------------
# 追加到 target/linux/mediatek/image/filogic.mk 末尾。
#
# 为什么要移植：ImmortalWrt openwrt-25.12 分支**没有**这块板子
#   （实测 filogic.mk 里 tenda_be12-pro 出现 0 次，190 个 filogic 设备）。
#   但 MT7987 SoC 本身是支持的（bpi-r4-lite / mt7987a-rfb / be7200 等），
#   所以缺的只是「这台机器的描述」，而不是底层驱动。
#
# 需要移植的三件套（总计约 410 行）：
#   1) patches/immortalwrt-25.12/mt7987a-tenda-be12-pro.dts  设备树 390 行
#   2) 本文件里的 Build/tenda-mkdualimageheader               6 行
#   3) 本文件里的 Device/tenda_be12-pro                      14 行
#
# 三件都取自 openwrt/openwrt main 分支（板子 2026-03-09 之后才合入主线，
# 所有稳定版 24.10 / 25.12.0~.3 都没有）。
#
# ⚠️ 版本差异风险：ImmortalWrt 25.12 是 **内核 6.12**，主线 SNAPSHOT 是 6.18。
#    DTS 里用到的较新 binding（airoha,an8855-ext-surge、MT76 的 band@0/band@1
#    节点写法）6.12 未必认。真构建失败时先看 dtc 报的是哪个属性/节点。
#
# 由 scripts/apply-board-port.sh 自动追加，带 TENDA_PORT 标记，可重复执行。
# =============================================================================

# ---- 1. 原厂私有镜像头 ------------------------------------------------------
# 拼 \x47\x6f\x64\x31 ("God1") 魔数 + 8 字节 gzip CRC 尾。
# ⚠️ **没有这个原厂 bootloader 不认镜像，sysupgrade 会失败。**
#    不可修改、不可删除。
define Build/tenda-mkdualimageheader
	printf '%b' "\x47\x6f\x64\x31\x00\x00\x00\x00" >"$@.new"
	gzip -c "$@" | tail -c8 >>"$@.new"
	cat "$@" >>"$@.new"
	mv "$@.new" "$@"
endef

# ---- 2. 板级定义 ------------------------------------------------------------
define Device/tenda_be12-pro
  DEVICE_VENDOR := Tenda
  DEVICE_MODEL := BE12 Pro
  DEVICE_DTS := mt7987a-tenda-be12-pro
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := mt7987-2p5g-phy-firmware airoha-en8811h-firmware kmod-phy-airoha-en8811h kmod-mt7992-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_LOADADDR := 0x40000000
  KERNEL_INITRAMFS := kernel-bin | lzma | \
        fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := append-kernel | tenda-mkdualimageheader | sysupgrade-tar kernel=$$$$@ | append-metadata
endef
TARGET_DEVICES += tenda_be12-pro
