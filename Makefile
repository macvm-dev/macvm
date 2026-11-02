# 唯一构建入口。签名身份默认 ad-hoc；发布时传 SIGN_IDENTITY="Developer ID Application: …"。
SIGN_IDENTITY ?= -
ENTITLEMENTS  ?= packaging/entitlements/base.entitlements
CONFIG        ?= debug
BIN           := .build/$(CONFIG)

.PHONY: build sign test lint agent app release clean

build:
	swift build -c $(CONFIG)

# VZ 拒绝没有 virtualization entitlement 的进程，开发时每次构建后都要重签。
sign: build
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/macvm
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/MacVMApp

test:
	swift test
	cd guest/agent && cargo test

lint:
	scripts/check-layers.sh

agent:
	scripts/build-agent.sh

app:
	CONFIG=release SIGN_IDENTITY="$(SIGN_IDENTITY)" ENTITLEMENTS="$(ENTITLEMENTS)" scripts/bundle-app.sh

release:
	$(MAKE) app CONFIG=release
	scripts/notarize.sh dist/MacVM.app

clean:
	rm -rf .build dist guest/agent/target
