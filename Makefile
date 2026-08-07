export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = SpringBoard
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
export THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = AirPodsVolume

AirPodsVolume_FILES = Tweak.xm
AirPodsVolume_CFLAGS = -fobjc-arc
AirPodsVolume_FRAMEWORKS = AVFoundation MediaPlayer

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
