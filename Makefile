TARGET := iphone:clang:latest:16.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = h3kb h3kb_plugin
THEOS_PACKAGE_SCHEME = roothide
FINALPACKAGE = 1

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
THEOS_PACKAGE_DIR = rootless
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
THEOS_PACKAGE_DIR = roothide
else
THEOS_PACKAGE_DIR = rootful
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = H3kbHook

H3kbHook_FILES = Tweak.xm
H3kbHook_CFLAGS = -fobjc-arc
H3kbHook_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
