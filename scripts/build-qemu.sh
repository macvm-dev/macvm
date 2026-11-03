#!/usr/bin/env bash
# 编译 App 自带的 QEMU 及其图形栈，打印产物目录（内含 bin/、lib/、share/、licenses/）。
# 产物缓存在 .build/qemu，脚本、qemu/ 下的清单与补丁、Homebrew 库版本都不变时直接复用。
#
# 画面走 SPICE + OpenGL：virglrenderer 经 ANGLE 用 Metal 重放客户机的 OpenGL，画面落在 IOSurface 上，
# App 进程里的 SPICE 客户端直接显示它。Windows 的 Direct3D 由 DXMT 转成 Metal，DXMT 的着色器翻译要
# LLVM 15，首次编译很久；MACVM_QEMU_DIRECT3D=0 时不编它（Windows 就没有 3D）。
#
# 所有源码按校验和固定在 qemu/sources.tsv。编译工具与 glib、pixman、openssl 用 Homebrew 的：
#   brew install cmake ninja meson pkgconf glib pixman openssl python
# 另需 Xcode 的 Metal 工具链：xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/scripts/build-qemu.sh
native=$root/qemu

qemu_version=11.1.2
direct3d=yes
[ "${MACVM_QEMU_DIRECT3D:-1}" = 1 ] || direct3d=no
# Homebrew 的库按本机系统编译，自带的 QEMU 因此要求同版本的 macOS；App 在更早的系统上不提供它。
export MACOSX_DEPLOYMENT_TARGET=27.0
configure_options=(
  --target-list=aarch64-softmmu --without-default-features
  --enable-hvf --disable-tcg --enable-coreaudio --enable-pixman --enable-fdt=internal --enable-slirp
  --enable-vnc --enable-spice --enable-opengl --enable-virglrenderer
  --disable-docs --disable-tools --disable-werror --enable-trace-backends=nop
)

fail() { echo "build-qemu: $*" >&2; exit 1; }

brew_prefix=${HOMEBREW_PREFIX:-/opt/homebrew}
for tool in cmake ninja meson pkg-config clang xcrun git; do
  command -v "$tool" >/dev/null || fail "缺少 ${tool}：brew install cmake ninja meson pkgconf glib pixman openssl python"
done
for library in glib-2.0 pixman-1 openssl slirp; do
  pkg-config --exists "$library" || fail "缺少 ${library}：brew install glib pixman openssl libslirp"
done
xcrun -sdk macosx metal --version >/dev/null 2>&1 || fail "缺少 Metal 工具链：xcodebuild -downloadComponent MetalToolchain"
# QEMU 的构建要读 TOML（tomllib），解包用 tarfile 的安全过滤器。
python=""
for candidate in "$brew_prefix/bin/python3" /usr/bin/python3; do
  if [ -x "$candidate" ] && "$candidate" -c 'import tomllib, tarfile; tarfile.data_filter' 2>/dev/null; then
    python=$candidate
    break
  fi
done
[ -n "$python" ] || fail "需要 Python 3.11.4 以上：brew install python"

key=$({ cat "$script" "$native"/sources.tsv "$native"/patches/* "$native"/display/*; echo "$direct3d"; pkg-config --modversion glib-2.0 pixman-1 openssl slirp; } | shasum -a 256 | cut -c1-12)
cache=$root/.build/qemu
result=$cache/$qemu_version-$key/QEMU
if [ -x "$result/bin/qemu-system-aarch64" ] && [ -f "$result/lib/libMacVMDisplay.dylib" ]; then
  echo "$result"
  exit 0
fi

# 源码与编出的库留着，下次增量编译；其余中间产物随本次结束删除。
sources=$cache/sources
prefix=$cache/prefix
mkdir -p "$sources" "$prefix"
work=$(mktemp -d "$cache/work.XXXXXX")
log=$cache/build.log
trap 'rm -rf "$work"' EXIT

fetch_sources() {
  local name checksum url part archive
  while IFS=$'\t' read -r name checksum url part; do
    [ -n "$name" ] || continue
    [ "$part" = all ] || [ "$direct3d" = yes ] || continue
    archive=$sources/$name
    if [ ! -f "$archive" ] || [ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$checksum" ]; then
      echo "下载 ${name}…" >&2
      curl --fail --silent --show-error --location --retry 3 -o "$archive.download" "$url" || fail "无法下载 $url"
      [ "$(shasum -a 256 "$archive.download" | cut -d' ' -f1)" = "$checksum" ] || fail "$name 的校验和与 sources.tsv 不符"
      mv "$archive.download" "$archive"
    fi
  done < "$native/sources.tsv"
}

# 把归档 $1 解到 sources/$2 并依次打上其后的补丁；归档或补丁变了才重新解包。
unpack() {
  local archive=$sources/$1 directory=$sources/$2 stamp patch_file
  shift 2
  stamp=$({ shasum -a 256 "$archive"; [ $# -eq 0 ] || cat "$@"; } | shasum -a 256 | cut -d' ' -f1)
  [ -f "$directory/.macvm-stamp" ] && [ "$(cat "$directory/.macvm-stamp")" = "$stamp" ] && return 0
  rm -rf "$directory" "$sources/.unpacking"
  mkdir "$sources/.unpacking"
  # 安全过滤器，但跳过指向树外的符号链接：QEMU 的归档里有一个，指向这里不编的固件。
  "$python" - "$archive" "$sources/.unpacking" <<'PY'
import sys, tarfile
def keep(member, path):
    if member.issym() and member.linkname.startswith('/'):
        return None
    return tarfile.data_filter(member, path)
with tarfile.open(sys.argv[1]) as source:
    source.extractall(sys.argv[2], filter=keep)
PY
  local unpacked=("$sources/.unpacking"/*)
  [ ${#unpacked[@]} -eq 1 ] || fail "$(basename "$archive") 没有解成单个目录"
  mv "${unpacked[0]}" "$directory"
  rmdir "$sources/.unpacking"
  for patch_file in "$@"; do
    patch --batch --forward -d "$directory" -p1 < "$patch_file" >/dev/null || fail "$(basename "$patch_file") 打不上 $(basename "$archive")"
  done
  echo "$stamp" > "$directory/.macvm-stamp"
}

meson_build() {
  local directory=$1
  shift
  local reconfigure=()
  # Meson 记住了上次找到的依赖路径（含 Homebrew 带版本号的目录），重新配置时清掉。
  [ ! -f "$directory/build/build.ninja" ] || reconfigure=(--reconfigure --clearcache)
  meson setup ${reconfigure[@]+"${reconfigure[@]}"} "$directory/build" "$directory" --prefix="$prefix" --libdir=lib \
    --buildtype=release -Dauto_features=disabled "$@"
  meson compile -C "$directory/build"
  meson install -C "$directory/build"
}

build_libraries() {
  [ -x "$cache/tools/bin/python3" ] || "$python" -m venv "$cache/tools"
  "$cache/tools/bin/python3" -m pip install --quiet PyYAML==6.0.3 pyparsing==3.2.3 six==1.17.0
  # 有的项目用 Meson 自带的 Python 跑生成器，同样要能找到这些包。
  PYTHONPATH=$("$cache/tools/bin/python3" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')
  export PYTHONPATH
  export PKG_CONFIG_PATH=$prefix/lib/pkgconfig:$prefix/share/pkgconfig:${PKG_CONFIG_PATH:-}
  export PATH=$cache/tools/bin:$brew_prefix/opt/gettext/bin:$PATH

  unpack spice-protocol-0.14.5.tar.xz spice-protocol
  meson_build "$sources/spice-protocol"
  unpack libjpeg-turbo-3.1.2.tar.gz libjpeg-turbo
  cmake -S "$sources/libjpeg-turbo" -B "$sources/libjpeg-turbo/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
  cmake --build "$sources/libjpeg-turbo/build"
  # CMake 安装时会就地改库的搜索路径，已是最新也改，先删掉旧的。
  rm -f "$prefix"/lib/libjpeg*.dylib
  cmake --install "$sources/libjpeg-turbo/build"
  unpack json-glib-1.10.0.tar.xz json-glib
  meson_build "$sources/json-glib" -Dintrospection=disabled -Dtests=false
  unpack libucontext.tar.gz libucontext
  meson_build "$sources/libucontext" -Ddefault_library=static -Dfreestanding=true
  # 画面不需要视频管线，声音走 QEMU 的 CoreAudio，不走 SPICE。
  unpack gstreamer-1.19.1.tar.xz gstreamer
  meson_build "$sources/gstreamer" -Dgst_parse=false -Dtests=disabled -Dexamples=disabled -Dbenchmarks=disabled \
    -Dtools=disabled -Dintrospection=disabled
  unpack gst-plugins-base-1.19.1.tar.xz gst-plugins-base "$sources/gst-plugins-base-1.19.1.patch"
  meson_build "$sources/gst-plugins-base" -Dtests=disabled -Dexamples=disabled -Dtools=disabled -Dgl=disabled \
    -Dintrospection=disabled
  unpack spice-0.16.0.tar.bz2 spice "$native/patches/spice-server.patch" "$native/patches/spice-input-lifetime.patch"
  meson_build "$sources/spice" -Dlz4=false -Dsasl=false -Dgstreamer=no -Dmanual=false -Dtests=false
  unpack spice-gtk-0.42.tar.xz spice-gtk "$sources/spice-gtk-0.42.patch"
  meson_build "$sources/spice-gtk" -Dcoroutine=libucontext -Dintrospection=disabled -Dgtk=disabled -Dwebdav=disabled \
    -Dusbredir=disabled -Dwayland-protocols=disabled

  # UTM 的 WebKit 里的 ANGLE，能与 Metal 共享纹理。稀疏检出，只取 ANGLE。
  local angle_commit=ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10
  if [ ! -d "$sources/WebKit/.git" ]; then
    git clone --quiet --filter=tree:0 --no-checkout https://github.com/utmapp/WebKit.git "$sources/WebKit"
    git -C "$sources/WebKit" sparse-checkout set Source/ThirdParty/ANGLE Configurations Tools/ccache
  fi
  local angle=$sources/WebKit/Source/ThirdParty/ANGLE angle_patch=$native/patches/angle-dylibs.patch
  if [ "$(git -C "$sources/WebKit" rev-parse HEAD 2>/dev/null)" != $angle_commit ] || [ ! -f "$angle/.macvm-patched" ]; then
    git -C "$sources/WebKit" checkout --quiet --force $angle_commit
    patch --batch -d "$angle" -p1 < "$angle_patch" >/dev/null || fail "angle-dylibs.patch 打不上 ANGLE"
    touch "$angle/.macvm-patched"
  fi
  local angle_build=(xcodebuild archive -archivePath "$prefix/ANGLE" -scheme ANGLE -sdk macosx -arch arm64 -configuration Release
    WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR= CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO
    MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET 'WK_LIBCPP_ASSERTIONS_CFLAGS_MACOS_SINCE_1400=-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE')
  # Xcode 的中间产物在缓存之外，ANGLE 只在它的输入变了才重编。
  local angle_stamp
  angle_stamp=$({ echo "${angle_build[*]}"; git -C "$sources/WebKit" rev-parse HEAD; cat "$angle_patch"; xcodebuild -version; } | shasum -a 256 | cut -d' ' -f1)
  if [ ! -f "$prefix/ANGLE.xcarchive/.macvm-stamp" ] || [ "$(cat "$prefix/ANGLE.xcarchive/.macvm-stamp")" != "$angle_stamp" ]; then
    (cd "$angle" && "${angle_build[@]}")
    echo "$angle_stamp" > "$prefix/ANGLE.xcarchive/.macvm-stamp"
  fi
  cp -R "$prefix/ANGLE.xcarchive/Products/usr/local/lib/" "$prefix/lib/"
  cp -R "$angle/include/" "$prefix/include/"
  unpack epoxy.tar.gz epoxy "$native/patches/epoxy-dylibs.patch"
  meson_build "$sources/epoxy" -Dtests=false -Dglx=no -Degl=yes -Dx11=false "-Dc_args=-I$prefix/include"
  unpack virglrenderer.tar.gz virglrenderer
  meson_build "$sources/virglrenderer" -Dtests=false -Dvtest=false -Dvenus=false -Dneptune=true -Dcheck-gl-errors=false \
    -Drender-server-mode=process "-Dc_args=-I$prefix/include"

  [ "$direct3d" = yes ] || return 0
  # DXMT 的着色器翻译只认 LLVM 15，单独编一份它的库，与本机的 LLVM 无关。
  unpack llvm-project-15.0.7.src.tar.xz llvm-project
  cmake -S "$sources/llvm-project/llvm" -B "$sources/llvm-project/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix/llvm15" -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_TARGETS_TO_BUILD= -DLLVM_BUILD_TOOLS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=OFF
  cmake --build "$sources/llvm-project/build"
  cmake --install "$sources/llvm-project/build"
  unpack directx.tar.gz directx-headers
  unpack dxmt.tar.gz dxmt "$native/patches/dxmt-shared-resource-initialization.patch" "$native/patches/dxmt-shared-resource-tests.patch"
  if [ ! -e "$sources/dxmt/include/native/directx/d3d11.h" ]; then
    rmdir "$sources/dxmt/include/native/directx"
    ln -s ../../../directx-headers "$sources/dxmt/include/native/directx"
  fi
  meson_build "$sources/dxmt" -Dnative_llvm_path="$prefix/llvm15"
}

# App 显示画面用的库：CocoaSpice（UTM 的 SPICE 客户端与 Metal 渲染器）加 MacVMDisplay.m 的 C 接口。
build_display() {
  unpack cocoaspice-pinned.tar.gz cocoaspice "$native/patches/cocoaspice-renderer.patch" \
    "$native/patches/cocoaspice-screenshot.patch" "$native/patches/cocoaspice-seamless.patch" \
    "$native/patches/cocoaspice-device-area.patch" "$native/patches/cocoaspice-scanout-peek.patch" \
    "$native/patches/cocoaspice-present-on-attach.patch"
  local cocoa=$sources/cocoaspice
  local renderer=$cocoa/Sources/CocoaSpiceRenderer client=$cocoa/Sources/CocoaSpice
  local module=$work/display-module objects=$work/display-objects file
  mkdir -p "$module/CocoaSpiceRenderer" "$objects" "$prefix/share/CocoaSpice_CocoaSpiceRenderer.bundle"
  cp "$renderer"/include/*.h "$module/CocoaSpiceRenderer/"
  echo 'module CocoaSpiceRenderer { umbrella header "CocoaSpiceRenderer.h" export * }' > "$module/CocoaSpiceRenderer/module.modulemap"
  local flags=(-fobjc-arc -fmodules -O2 -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET
    -I"$module" -I"$client" -I"$client/include" -I"$renderer/include" -I"$native/display")
  # shellcheck disable=SC2207
  flags+=($(pkg-config --cflags spice-client-glib-2.0 gstreamer-1.0))
  local compiled=()
  for file in "$client"/*.m "$renderer/CSMetalRenderer.m" "$native/display/MacVMDisplay.m"; do
    case $(basename "$file") in gst_ios_init.m | CSUSBDevice.m | CSUSBManager.m) continue ;; esac
    clang "${flags[@]}" -c "$file" -o "$objects/$(basename "${file%.m}").o"
    compiled+=("$objects/$(basename "${file%.m}").o")
  done
  # shellcheck disable=SC2046
  clang -dynamiclib -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -install_name @rpath/libMacVMDisplay.dylib \
    "${compiled[@]}" -framework AppKit -framework Metal -framework MetalKit -framework IOSurface -framework QuartzCore \
    -framework CoreGraphics $(pkg-config --libs spice-client-glib-2.0 gstreamer-1.0) -o "$prefix/lib/libMacVMDisplay.dylib"
  xcrun -sdk macosx metal -c "$renderer/CSShaders.metal" -I"$renderer/include" -o "$objects/CSShaders.air"
  xcrun -sdk macosx metallib "$objects/CSShaders.air" -o "$prefix/share/CocoaSpice_CocoaSpiceRenderer.bundle/default.metallib"
}

build_qemu() {
  # 编译目录跟着源码，补丁变了随源码一起重建；configure 每次重新配置 Meson。
  unpack qemu-$qemu_version.tar.xz qemu "$native"/patches/qemu-*.patch
  mkdir -p "$sources/qemu/build"
  (
    cd "$sources/qemu/build"
    ../configure --python="$python" --prefix=/ --extra-cflags="-I$prefix/include" "${configure_options[@]}"
    ninja qemu-system-aarch64
  )
}

# 把 $1 依赖的非系统库拷进 lib/ 并递归处理，引用一律改成 @rpath/<名字>。
copy_libraries() {
  local file=$1 reference original name
  for reference in $(otool -L "$file" | tail -n +2 | awk '{ print $1 }'); do
    case $reference in /usr/lib/* | /System/*) continue ;; esac
    name=$(basename "$reference")
    [ "$name" != "$(basename "$file")" ] || continue
    original=$reference
    case $reference in @*) original=$prefix/lib/$name ;; esac
    if [ ! -f "$out/lib/$name" ]; then
      [ -f "$original" ] || fail "QEMU 依赖的 $original 不存在"
      cp -L "$original" "$out/lib/$name"
      chmod u+w "$out/lib/$name"
      install_name_tool -id "@rpath/$name" "$out/lib/$name" 2>/dev/null
      copy_libraries "$out/lib/$name"
    fi
    install_name_tool -change "$reference" "@rpath/$name" "$file" 2>/dev/null
  done
}

package() {
  local source_dir=$sources/qemu name file search_path minimum
  out=$work/QEMU
  mkdir -p "$out/bin" "$out/lib" "$out/share/keymaps" "$out/licenses"
  cp "$source_dir/build/qemu-system-aarch64" "$out/bin/"
  cp "$prefix/libexec/virgl_render_server" "$out/bin/"
  # 运行时才打开、没有被链接的库：epoxy 打开 ANGLE，virglrenderer 打开 DXMT。
  local opened=(libMacVMDisplay.dylib libEGL.dylib libGLESv2.dylib)
  [ "$direct3d" != yes ] || opened+=(libdxmt-native.dylib)
  for name in "${opened[@]}"; do
    cp -L "$prefix/lib/$name" "$out/lib/$name"
    chmod u+w "$out/lib/$name"
    install_name_tool -id "@rpath/$name" "$out/lib/$name"
    copy_libraries "$out/lib/$name"
  done
  for file in "$out"/bin/*; do copy_libraries "$file"; done
  for file in "$out"/bin/* "$out"/lib/*.dylib; do
    for search_path in $(otool -l "$file" | awk '/cmd LC_RPATH/ { found=1; next } found && $1 == "path" { print $2; found=0 }'); do
      install_name_tool -delete_rpath "$search_path" "$file" 2>/dev/null
    done
    case $file in
      "$out"/bin/*) install_name_tool -add_rpath @executable_path/../lib "$file" 2>/dev/null; strip -x "$file" 2>/dev/null ;;
      *) install_name_tool -add_rpath @loader_path "$file" 2>/dev/null ;;
    esac
    if otool -L "$file" | tail -n +2 | awk '{ print $1 }' | grep -q -e "^$brew_prefix" -e "^$cache"; then
      fail "$(basename "$file") 仍引用 Homebrew 或编译目录里的库"
    fi
    # Homebrew 的库按本机系统版本编译，可能高于 App 支持的最低版本。
    minimum=$(vtool -show-build "$file" | awk '$1 == "minos" { print $2; exit }')
    [ "$(printf '%s\n%s\n' "$minimum" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1)" = "$MACOSX_DEPLOYMENT_TARGET" ] \
      || fail "$(basename "$file") 要求 macOS ${minimum}，高于 App 的 $MACOSX_DEPLOYMENT_TARGET"
  done

  # 固件补零到 64MB 闪存大小，几乎全是零；只留实际内容并按 64KB 对齐。
  for name in edk2-aarch64-code.fd edk2-arm-vars.fd; do
    bunzip2 -c "$source_dir/pc-bios/$name.bz2" > "$work/$name"
    "$python" -c '
import sys
data = open(sys.argv[1], "rb").read().rstrip(b"\0")
open(sys.argv[2], "wb").write(data + b"\0" * (-len(data) % 65536))
' "$work/$name" "$out/share/$name"
  done
  # VNC 服务端没有键盘布局文件不肯启动，尽管按键按扫描码送、与布局无关。
  cp "$source_dir/pc-bios/keymaps/en-us" "$out/share/keymaps/"
  # CocoaSpice 在 App 的 Resources 下按这个名字找 Metal 着色器。
  cp -R "$prefix/share/CocoaSpice_CocoaSpiceRenderer.bundle" "$out/share/"
  [ "$direct3d" != yes ] || cp "$sources/viogpu3d-arm64x-signed.zip" "$out/share/"

  cp "$source_dir/COPYING" "$out/licenses/QEMU-COPYING"
  cp "$source_dir/COPYING.LIB" "$out/licenses/QEMU-COPYING.LIB"
  cp "$source_dir/LICENSE" "$out/licenses/QEMU-LICENSE"
  cp "$source_dir/pc-bios/edk2-licenses.txt" "$out/licenses/"
  cp "$native"/patches/*.patch "$native/sources.tsv" "$out/licenses/"
  cp "$script" "$out/licenses/build-qemu.sh"
  "$python" - "$sources" "$out/licenses" "$direct3d" <<'PY'
import pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:3])
direct3d = sys.argv[3] == 'yes'
for name in source.glob('*'):
    if name.is_file() and (name.name.startswith('triton-') or name.name.startswith('mesa-')) and direct3d:
        shutil.copy2(name, target / name.name)
for component in source.iterdir():
    if not component.is_dir() or component.name in ('WebKit', 'llvm-project', 'qemu'):
        continue
    if not direct3d and component.name in ('dxmt', 'directx-headers'):
        continue
    for pattern in ('COPYING*', 'LICENSE*', 'LICENCE*'):
        for path in component.glob(pattern):
            dest = target / component.name
            dest.mkdir(exist_ok=True)
            if path.is_file():
                shutil.copy2(path, dest / path.name)
            elif path.is_dir():
                shutil.copytree(path, dest / path.name, dirs_exist_ok=True)
angle = source / 'WebKit/Source/ThirdParty/ANGLE'
for pattern in ('LICENSE*', 'COPYING*'):
    for path in angle.rglob(pattern):
        if path.is_file():
            dest = target / 'ANGLE' / path.relative_to(angle)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
if direct3d:
    shutil.copy2(source / 'llvm-project/llvm/LICENSE.TXT', target / 'LLVM-LICENSE.TXT')
    shutil.copy2(source / 'dxmt/src/util/dxvk.LICENSE', target / 'DXVK-LICENSE')
PY
  local license
  for license in glib/LGPL-2.1-or-later.txt pixman/COPYING pcre2/LICENCE.md openssl/LICENSE.txt gettext/COPYING libslirp/COPYRIGHT; do
    if [ -f "$brew_prefix/opt/$license" ]; then
      cp "$brew_prefix/opt/$license" "$out/licenses/${license%%/*}-$(basename "$license")"
    fi
  done
  cat > "$out/README.txt" <<EOF
QEMU $qemu_version, built for MacVM with graphics acceleration on macOS.

QEMU is free software under the GNU General Public License, version 2. Its source is at
https://download.qemu.org/qemu-$qemu_version.tar.xz, with the patches in licenses/, and it was
configured with:
  ${configure_options[*]}
licenses/build-qemu.sh builds it and everything else here; licenses/sources.tsv names every
source that went in, with its checksum. The graphics patches come from UTM's QEMU
(github.com/utmapp/qemu) as ported to QEMU 11.1 by SwiftVM.

lib/libMacVMDisplay.dylib is CocoaSpice (Apache 2.0, github.com/utmapp/CocoaSpice) with
MacVM's display interface. The other libraries in lib/ are SPICE, GStreamer, json-glib, libjpeg-turbo, libepoxy, virglrenderer
and ANGLE built from those sources, and Homebrew's builds of glib, pixman, OpenSSL, PCRE2,
libslirp and gettext's libintl. The firmware in share/ is EDK II as it comes with QEMU's
source. The licences are in licenses/.
EOF
  [ "$direct3d" != yes ] || printf '\n%s\n' "lib/libdxmt-native.dylib is DXMT (LGPL 2.1), built with LLVM 15. share/viogpu3d-arm64x-signed.zip
is the Windows driver from github.com/osy/kvm-guest-drivers-windows v0.3." >> "$out/README.txt"

  # 先 ad-hoc 签名以便本机直接运行；打包进 App 时再正式签名。
  for file in "$out"/lib/*.dylib "$out/bin/virgl_render_server"; do codesign --force --sign - "$file" 2>/dev/null; done
  codesign --force --sign - --entitlements "$root/packaging/entitlements/qemu.entitlements" "$out/bin/qemu-system-aarch64" 2>/dev/null
  "$out/bin/qemu-system-aarch64" --version >/dev/null || fail "编出的 QEMU 无法运行"
}

echo "编译 QEMU $qemu_version 与图形栈（首次较久），日志：$log" >&2
fetch_sources
set +e
(
  set -e
  build_libraries
  build_display
  build_qemu
) > "$log" 2>&1
built=$?
set -e
[ $built -eq 0 ] || fail "编译失败，见 ${log}：
$(tail -30 "$log")"
package

for earlier in "$cache"/*-*/; do
  [ "$earlier" = "$cache/$qemu_version-$key/" ] || rm -rf "$earlier"
done
mkdir -p "$(dirname "$result")"
mv "$out" "$result"
echo "$result"
