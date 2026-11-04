# 唯一构建入口。签名身份默认 ad-hoc；发布时传 SIGN_IDENTITY="Developer ID Application: …"。
SIGN_IDENTITY ?= -
ENTITLEMENTS  ?= packaging/entitlements/base.entitlements
CONFIG        ?= debug
BIN           := .build/$(CONFIG)

.PHONY: build sign test lint agent boot qemu app release clean

build:
	swift build -c $(CONFIG)

# VZ 拒绝没有 virtualization entitlement 的进程，开发时每次构建后都要重签。
sign: build
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/macvm
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/MacVMApp

test:
	swift test
	cd guest && cargo test

lint:
	scripts/check-layers.sh

agent:
	scripts/build-agent.sh

boot:
	scripts/build-boot.sh

qemu:
	scripts/build-qemu.sh

app:
	CONFIG=release SIGN_IDENTITY="$(SIGN_IDENTITY)" ENTITLEMENTS="$(ENTITLEMENTS)" scripts/bundle-app.sh

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
