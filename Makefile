export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
export THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = AirPodsVolume

AirPodsVolume_FILES = Tweak.xm
AirPodsVolume_CFLAGS = -fobjc-arc
AirPodsVolume_FRAMEWORKS = AVFoundation
# 控制中心 1x1：代码里直接引用了 CCUIModuleSettings 类（[[CCUIModuleSettings alloc] init...]），
# 编译期会生成 _OBJC_CLASS_$_CCUIModuleSettings 符号，不链接该私有框架会
# "Undefined symbols for architecture arm64e" 链接失败。
AirPodsVolume_PRIVATE_FRAMEWORKS = ControlCenterUI

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
