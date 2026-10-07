ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppleTraceTweak
AppleTraceTweak_FILES = \
    Tweak/AppleTraceTweak.m \
    Tweak/AgentTransport.m \
    ../appletrace/appletrace/src/appletrace.mm \
    ../appletrace/appletrace/src/objc/hook_objc_msgSend.m
AppleTraceTweak_CFLAGS = -fobjc-arc -I../appletrace/appletrace/src
AppleTraceTweak_CCFLAGS = -std=c++17
AppleTraceTweak_FRAMEWORKS = Foundation
AppleTraceTweak_LIBRARIES = substrate

TOOL_NAME = appletraced
appletraced_FILES = Daemon/main.m Daemon/AgentRegistry.m Daemon/ControlServer.m
appletraced_CFLAGS = -fobjc-arc
appletraced_FRAMEWORKS = Foundation
appletraced_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/libexec/appletraced" "$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.everettjf.appletraced.plist"
	mkdir -p "$(THEOS_STAGING_DIR)/usr/share/appletrace"
	cp -R "../Sources/AppleTraceServer/Resources/Console" "$(THEOS_STAGING_DIR)/usr/share/appletrace/console"

after-install::
	install.exec "launchctl kickstart -k system/com.everettjf.appletraced || true"
