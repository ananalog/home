# Home — top-level tasks. Components live in submodules: protocol/ server/ firmware/ android/.
HOST ?=
DEVICE ?= co2-egg

.PHONY: init update check build test server firmware android deploy fw-publish bootstrap

init:            ## clone/refresh all submodules
	git submodule update --init --recursive

update:          ## move every component to its latest main (commit the result in this repo)
	git submodule update --remote --recursive
	scripts/check-protocol.sh

check:           ## all components use the same protocol
	scripts/check-protocol.sh

build:           ## everything into dist/ (tests included)
	scripts/build-all.sh

test:            ## protocol vectors (C, C#, Kotlin), server, android core
	protocol/scripts/test.sh
	dotnet test server/home-server.slnx
	cd android && ./gradlew :core:test --no-daemon

server:          ## server release archive → server/dist/
	server/scripts/publish.sh

firmware:        ## one device firmware → firmware/dist/$(DEVICE)/
	firmware/scripts/fw-build.sh $(DEVICE)

android:         ## debug APK (needs Android SDK)
	cd android && ./gradlew :app:assembleDebug

deploy:          ## make deploy HOST=user@192.168.1.10
	@test -n "$(HOST)" || (echo "HOST=user@host required" && exit 1)
	scripts/deploy.sh $(HOST)

fw-publish:      ## make fw-publish HOST=user@192.168.1.10 [DEVICE=co2-egg]
	@test -n "$(HOST)" || (echo "HOST=user@host required" && exit 1)
	scripts/fw-publish.sh $(HOST) $(DEVICE)

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'
