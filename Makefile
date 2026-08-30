export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
export THEOS_PACKAGE_SCHEME = rootless

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
