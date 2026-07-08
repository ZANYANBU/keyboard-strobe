SWIFT_FILES = Sources/KeyboardStrobe/main.swift
APP_NAME = KeyboardStrobe
BUNDLE_ID = com.zanyanbu.keyboardstrobe
APP_DIR = $(APP_NAME).app
MACOS_DIR = $(APP_DIR)/Contents/MacOS
RESOURCES_DIR = $(APP_DIR)/Contents/Resources
BINARY_NAME = $(MACOS_DIR)/$(APP_NAME)
INFOPLIST = Info.plist

all: app

app: $(SWIFT_FILES) $(INFOPLIST)
	@echo "Building $(APP_NAME).app..."
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(INFOPLIST) $(APP_DIR)/Contents/Info.plist
	@cp AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns
	swiftc -O -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(INFOPLIST) $(SWIFT_FILES) -o $(BINARY_NAME)
	@echo "Build successful! You can now run $(APP_DIR)"

zip: app
	@echo "Zipping $(APP_DIR) for release..."
	@zip -r -X $(APP_NAME).zip $(APP_DIR)
	@echo "Created $(APP_NAME).zip"

clean:
	@rm -rf $(APP_DIR)
	@rm -f $(APP_NAME).zip
	@rm -f keyboard-strobe

.PHONY: all app zip clean
