# Reboot — App-Store für alte iPods (iOS 6.1, ARMv7), Theos.
# Katalog + Pakete kommen von github.com/SecondTrack; installiert wird über den setuid-Helfer rbhelper.
TARGET = iphone:clang:7.1:6.0
ARCHS  = armv7

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Shop
Shop_FILES  = $(wildcard src/*.m)
Shop_FRAMEWORKS = UIKit CoreGraphics QuartzCore Foundation
Shop_CFLAGS  = -fobjc-arc -O2 -Wall -Isrc -Ivendor/mbedtls/include
Shop_LDFLAGS = -Lvendor/mbedtls/lib
Shop_LIBRARIES = mbedtls mbedx509 mbedcrypto
Shop_CODESIGN_FLAGS = -S$(THEOS_PROJECT_DIR)/ent.plist

# Installations-Helfer: liegt im App-Bundle, bekommt per postinst root:wheel + 4755
TOOL_NAME = rbhelper
rbhelper_FILES = src/rbhelper.c
rbhelper_CFLAGS = -Wall
rbhelper_INSTALL_PATH = /Applications/Shop.app

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk
