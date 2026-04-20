APP_NAME := VoiceInput
APP_BUNDLE := $(APP_NAME).app
BUILD_DIR := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/release)

.PHONY: build clean install run release

build:
	swift build -c release
	$(eval BUILD_DIR := $(shell swift build -c release --show-bin-path))
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "\n✅ Built $(APP_BUNDLE)"

run: install
	@killall $(APP_NAME) 2>/dev/null; true
	@sleep 1
	/Applications/$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) &
	@echo "✅ Running $(APP_NAME)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)

install: build
	rm -rf /Applications/$(APP_BUNDLE)
	cp -r $(APP_BUNDLE) /Applications/
	xattr -cr /Applications/$(APP_BUNDLE)
	@echo "✅ Installed to /Applications/$(APP_BUNDLE)"

# Usage: make release VERSION=1.2.0
release:
ifndef VERSION
	$(error VERSION is required. Usage: make release VERSION=1.2.0)
endif
	@CURRENT_BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist); \
	NEW_BUILD=$$((CURRENT_BUILD + 1)); \
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Info.plist; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$NEW_BUILD" Info.plist; \
	git add Info.plist; \
	git commit -m "chore: bump version to $(VERSION)"; \
	git tag v$(VERSION); \
	echo "✅ Tagged v$(VERSION). Push with: git push && git push --tags"
