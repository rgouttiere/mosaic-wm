APP_NAME := Mosaic
BUNDLE := $(APP_NAME).app
CONFIG := release
BIN := .build/$(CONFIG)/$(APP_NAME)
# Stable self-signed identity so the Accessibility grant survives rebuilds.
# Run `make cert` once. Falls back to ad-hoc ("-") if the identity is missing.
SIGN_ID := Mosaic Self-Signed

PREFIX ?= /usr/local
.PHONY: build bundle run clean cert dist install-cli test spike agent agent-unload restart deploy

## Create the stable self-signed dev identity (run once).
cert:
	./scripts/dev-cert.sh

## Compile the executable.
build:
	swift build -c $(CONFIG)

## Run the in-module self-test suite (pure logic: layout tree + config parsing).
## Debug build so the #if DEBUG `--self-test` entry point is compiled in. No Xcode needed.
test:
	swift build
	.build/debug/$(APP_NAME) --self-test

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
	@# Verify what actually landed. codesign can fail quietly against a locked keychain and leave the
	@# linker's ad-hoc signature in place: TCC then sees an unknown app, the Accessibility grant does
	@# not apply, AX enumerates nothing and Mosaic runs managing zero windows (2026-10-01). Fail here.
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		codesign -dvv $(BUNDLE) 2>&1 | grep -q "^Authority=$(SIGN_ID)$$" \
			|| { echo "ERROR: $(BUNDLE) is NOT signed with '$(SIGN_ID)' (ad-hoc?) — the Accessibility grant would not apply. Unlock the login keychain and rebuild."; exit 1; }; \
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

## Symlink the `mosaic` CLI to $(PREFIX)/bin (talks to the running app).
install-cli: bundle
	@mkdir -p $(PREFIX)/bin
	ln -sf "$(CURDIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)" "$(PREFIX)/bin/mosaic"
	@echo "Installed 'mosaic' → $(PREFIX)/bin/mosaic. Try: mosaic --list"

## Build + sign + run the M0 emulated-workspace spike (THROWAWAY, v2-emulated).
## Signed with the stable identity so the Accessibility grant survives rebuilds.
## First run: grant Accessibility to the printed binary path, then re-run.
spike:
	swift build --product MosaicSpike
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		codesign --force --sign "$(SIGN_ID)" .build/debug/MosaicSpike; \
	else \
		echo "WARNING: '$(SIGN_ID)' not found — run 'make cert' (grant will reset each build)."; \
		codesign --force --sign - .build/debug/MosaicSpike; \
	fi
	@echo "Running spike ($(CURDIR)/.build/debug/MosaicSpike)"
	.build/debug/MosaicSpike

clean:
	rm -rf .build $(BUNDLE) dist Mosaic.zip

## --- Launch agent: keep one Mosaic alive --------------------------------------------------------
## A crash at wake once left the desktop without a window manager until morning. Under launchd with
## KeepAlive (SuccessfulExit = false) a crash is followed by a relaunch within seconds, while Quit
## from the menu (exit 0) stays quit. RunAtLoad starts it at login. The agent runs the bundle built
## here, so `make deploy` is the whole update ritual: rebuild, verify the signature, restart.
AGENT_LABEL := fr.rgouttiere.mosaic
AGENT_PLIST := $(HOME)/Library/LaunchAgents/$(AGENT_LABEL).plist
AGENT_TARGET := gui/$(shell id -u)/$(AGENT_LABEL)

## Install (or refresh) the launch agent and start Mosaic under it. Stops a manually launched one first.
agent: bundle
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>$(AGENT_LABEL)</string>' \
	  '  <key>ProgramArguments</key><array><string>$(CURDIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)</string></array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>' \
	  '  <key>ProcessType</key><string>Interactive</string>' \
	  '  <key>LimitLoadToSessionType</key><string>Aqua</string>' \
	  '</dict></plist>' > "$(AGENT_PLIST)"
	@launchctl bootout $(AGENT_TARGET) 2>/dev/null || true
	@killall $(APP_NAME) 2>/dev/null && sleep 1 || true
	launchctl bootstrap gui/$(shell id -u) "$(AGENT_PLIST)"
	@echo "Agent loaded: $(AGENT_TARGET) → $(CURDIR)/$(BUNDLE). Restart with 'make restart', remove with 'make agent-unload'."

## Stop the agent and remove it (Mosaic is left stopped).
agent-unload:
	@launchctl bootout $(AGENT_TARGET) 2>/dev/null || true
	@rm -f "$(AGENT_PLIST)"
	@echo "Agent removed."

## Restart the running Mosaic: under the agent with kickstart, else the plain kill + open.
## Every Mosaic process goes first, not just the agent's: a Quit from the menu followed by a manual
## launch leaves an instance launchd does not own, the agent's fresh instance then finds it and
## exits (single-instance guard), and "Restarted under launchd" is a lie — deploys stopped landing
## for twenty minutes that way (2026-10-03). doctor flags the state; this makes restart repair it.
restart:
	@killall $(APP_NAME) 2>/dev/null && sleep 1 || true
	@if launchctl print $(AGENT_TARGET) >/dev/null 2>&1; then \
		launchctl kickstart -k $(AGENT_TARGET) && echo "Restarted under launchd."; \
	else \
		open $(BUNDLE) && echo "Restarted (no agent loaded)."; \
	fi

## The update ritual: self-tests green, rebuild + verify the signature (bundle does both), restart.
## `test` first: a binary that crashes at launch under the agent is a respawn loop, and a shell
## pipeline (`make test | grep …`) reports the grep's status, not make's — this target does not.
deploy: test bundle restart
