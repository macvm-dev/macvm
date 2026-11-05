# 唯一构建入口。签名身份默认 ad-hoc；发布时传 SIGN_IDENTITY="Developer ID Application: …"。
SIGN_IDENTITY ?= -
ENTITLEMENTS  ?= packaging/entitlements/base.entitlements
CONFIG        ?= debug
BIN           := .build/$(CONFIG)
# 钥匙串里唯一的 Developer ID Application 证书，零张或多张时为空；用到时才查。
DEVELOPER_ID   = $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"$$/\1/p' | awk '{ n++; id = $$0 } END { if (n == 1) print id }')
# swift build 链接时不把 SDK 路径交给 clang，二进制记下的 SDK 版本会退成部署目标，
# 系统据此按旧版外观（兼容模式）显示 App；显式传 -isysroot 让它记成实际使用的 SDK。
SDK_PATH      := $(shell xcrun --sdk macosx --show-sdk-path 2>/dev/null)
SWIFT_FLAGS   := $(if $(SDK_PATH),-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc $(SDK_PATH),$(warning 找不到 macOS SDK（xcrun --sdk macosx --show-sdk-path），App 将以旧版外观构建))

.PHONY: build sign run test test-swift test-guest lint lint-guest agent boot qemu icon app release clean

build:
	swift build -c $(CONFIG) $(SWIFT_FLAGS)

# VZ 拒绝没有 virtualization entitlement 的进程，开发时每次构建后都要重签。
sign: build
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/macvm
	codesign -f -s "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN)/MacVMApp

# 按 CONFIG（默认 debug）组装 App 并在前台运行，日志打在终端，Ctrl-C 退出。
# 组装进 .build 而不是 dist，不覆盖发布产物；直接运行可执行文件而不用 open，免得 LaunchServices 转去激活已在运行的同 bundle ID 的 App。
# 没传 SIGN_IDENTITY（命令行与环境变量都没有）时用 DEVELOPER_ID，没有才 ad-hoc：ad-hoc 签名时 launchd 按 cdhash 认网络辅助程序，每次重新构建都得重新注册。
run:
	APP=.build/MacVM.app CONFIG=$(CONFIG) SIGN_IDENTITY="$(if $(filter file,$(origin SIGN_IDENTITY)),$(or $(DEVELOPER_ID),-),$(SIGN_IDENTITY))" ENTITLEMENTS="$(ENTITLEMENTS)" SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle-app.sh
	.build/MacVM.app/Contents/MacOS/MacVM

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

icon:
	scripts/build-icon.sh

app:
	CONFIG=release SIGN_IDENTITY="$(SIGN_IDENTITY)" ENTITLEMENTS="$(ENTITLEMENTS)" SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle-app.sh

# 产出公证过的 dist/MacVM.app 与 dist/MacVM.dmg。公证不收 ad-hoc 签名：没传 SIGN_IDENTITY 时用 DEVELOPER_ID，没有就停下。
release:
	@id='$(if $(filter -,$(SIGN_IDENTITY)),$(DEVELOPER_ID),$(SIGN_IDENTITY))'; \
	if [ -z "$$id" ]; then \
	  echo "找不到唯一的 Developer ID Application 证书，用 make release SIGN_IDENTITY=\"Developer ID Application: …\" 指定" >&2; \
	  security find-identity -v -p codesigning >&2; exit 1; \
	fi; \
	echo "签名身份：$$id"; \
	set -e; \
	$(MAKE) app CONFIG=release SIGN_IDENTITY="$$id"; \
	scripts/notarize.sh dist/MacVM.app; \
	SIGN_IDENTITY="$$id" scripts/make-dmg.sh dist/MacVM.app dist/MacVM.dmg; \
	scripts/notarize.sh dist/MacVM.dmg

clean:
	rm -rf .build dist guest/target
