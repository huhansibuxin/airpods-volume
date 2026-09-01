export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
# scheme 由 CI/环境变量决定（rootless 默认，roothide 构建时 CI 传 roothide）；
# 必须用 ?= 条件赋值——make 里普通赋值会覆盖环境变量，roothide job 会被打回 rootless
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME

TWEAK_NAME = AirPodsVolume

AirPodsVolume_FILES = Tweak.xm
AirPodsVolume_CFLAGS = -fobjc-arc
AirPodsVolume_FRAMEWORKS = AVFoundation
# ⚠️ 不要加 AirPodsVolume_PRIVATE_FRAMEWORKS = ControlCenterUI：
# theos 的 iPhoneOS16.5.sdk 里没有这个私有框架，链接会直接失败
# (ld: framework 'ControlCenterUI' not found)。
# 代码里因此不能写 [CCUIModuleSettings alloc]（会生成 _OBJC_CLASS_$_CCUIModuleSettings
# 未定义符号），必须用 NSClassFromString 取到 Class 变量后再发消息。

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
