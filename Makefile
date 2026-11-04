# 唯一构建入口。签名身份默认 ad-hoc；发布时传 SIGN_IDENTITY="Developer ID Application: …"。
SIGN_IDENTITY ?= -
ENTITLEMENTS  ?= packaging/entitlements/base.entitlements
CONFIG        ?= debug
BIN           := .build/$(CONFIG)
# swift build 链接时不把 SDK 路径交给 clang，二进制记下的 SDK 版本会退成部署目标，
# 系统据此按旧版外观（兼容模式）显示 App；显式传 -isysroot 让它记成实际使用的 SDK。
SDK_PATH      := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
SWIFT_FLAGS   := $(if $(SDK_PATH),-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc $(SDK_PATH),$(warning 找不到 macOS SDK（xcrun --sdk macosx --show-sdk-path），App 将以旧版外观构建))

.PHONY: build sign test test-swift test-guest lint lint-guest agent boot qemu app release clean

build:
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

# VZ 拒绝没有 virtualization entitlement 的进程，开发时每次构建后都要重签。
sign: build
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/macvm
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/MacVMApp

test: test-swift test-guest

test-swift:
	swift test $(SWIFT_FLAGS)

test-guest:
	cd guest && cargo test

lint:
	scripts/check-layers.sh

lint-guest:
	scripts/lint-guest.sh

agent:
	scripts/build-agent.sh

boot:
	scripts/build-boot.sh

qemu:
	scripts/build-qemu.sh

app:
	CONFIG=release SIGN_IDENTITY="$(SIGN_IDENTITY)" ENTITLEMENTS="$(ENTITLEMENTS)" SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle-app.sh

# 公证不收 ad-hoc 签名：没传 SIGN_IDENTITY 时用钥匙串里唯一的 Developer ID Application 证书，有零张或多张就停下。
release:
	@id='$(SIGN_IDENTITY)'; \
	if [ "$$id" = "-" ]; then \
	  ids=$$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$$/\1/p'); \
	  if [ $$(printf '%s' "$$ids" | grep -c .) -ne 1 ]; then \
	    echo "找不到唯一的 Developer ID Application 证书，用 make release SIGN_IDENTITY=\"Developer ID Application: …\" 指定" >&2; \
	    printf '%s\n' "$$ids" >&2; exit 1; \
	  fi; \
	  id=$$ids; \
	fi; \
	echo "签名身份：$$id"; \
	$(MAKE) app CONFIG=release SIGN_IDENTITY="$$id"
	scripts/notarize.sh dist/MacVM.app

clean:
	rm -rf .build dist guest/target
