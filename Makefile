export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = AirPodsVolume

AirPodsVolume_FILES = Tweak.xm
AirPodsVolume_CFLAGS = -fobjc-arc
AirPodsVolume_LIBRARIES += substrate
AirPodsVolume_LOGOSFLAGS += -c generator=MobileSubstrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
