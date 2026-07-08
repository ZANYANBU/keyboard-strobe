SWIFT_FILES = Sources/KeyboardStrobe/main.swift
BINARY_NAME = keyboard-strobe
INFOPLIST = Info.plist
INSTALL_DIR = /usr/local/bin

all: $(BINARY_NAME)

$(BINARY_NAME): $(SWIFT_FILES) $(INFOPLIST)
	swiftc -O -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(INFOPLIST) $(SWIFT_FILES) -o $(BINARY_NAME)

install: $(BINARY_NAME)
	@echo "Installing keyboard-strobe to $(INSTALL_DIR)..."
	@mkdir -p $(INSTALL_DIR)
	@cp $(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME)
	@chmod +x $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Installation successful! Run 'keyboard-strobe' in any terminal window."

uninstall:
	@rm -f $(INSTALL_DIR)/$(BINARY_NAME)
	@echo "Uninstalled keyboard-strobe successfully."

clean:
	rm -f $(BINARY_NAME)

.PHONY: all install uninstall clean
