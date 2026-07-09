APP_NAME := Mosaic
BUNDLE := $(APP_NAME).app
CONFIG := release
BIN := .build/$(CONFIG)/$(APP_NAME)
# Stable self-signed identity so the Accessibility grant survives rebuilds.
# Run `make cert` once. Falls back to ad-hoc ("-") if the identity is missing.
SIGN_ID := Mosaic Self-Signed

.PHONY: build bundle run clean cert dist

## Create the stable self-signed dev identity (run once).
cert:
	./scripts/dev-cert.sh

## Compile the executable.
build:
	swift build -c $(CONFIG)

## Assemble a runnable .app bundle and codesign it with the stable identity.
## A stable signature keeps the Accessibility grant across rebuilds.
bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		echo "Signing with '$(SIGN_ID)'"; \
		codesign --force --deep --sign "$(SIGN_ID)" $(BUNDLE); \
	else \
		echo "WARNING: identity '$(SIGN_ID)' not found — run 'make cert'. Falling back to ad-hoc (grant will reset each build)."; \
		codesign --force --deep --sign - $(BUNDLE); \
	fi
	@echo "Built $(BUNDLE) — open it, then grant Accessibility in System Settings."

## Build the bundle and launch it.
run: bundle
	open $(BUNDLE)

## Build an arm64 (Apple Silicon), ad-hoc-signed .app zipped for sharing.
## Ad-hoc signing is self-contained → runs on any Apple Silicon Mac (after Gatekeeper bypass).
dist: build
	rm -rf dist Mosaic.zip
	mkdir -p dist/$(BUNDLE)/Contents/MacOS
	cp Resources/Info.plist dist/$(BUNDLE)/Contents/Info.plist
	cp $(BIN) dist/$(BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --deep --sign - dist/$(BUNDLE)
	ditto -c -k --keepParent dist/$(BUNDLE) Mosaic.zip
	@echo "Created Mosaic.zip (arm64, ad-hoc signed). Send it; see README for the tester steps."

clean:
	rm -rf .build $(BUNDLE) dist Mosaic.zip
