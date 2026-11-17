#!/bin/bash
# 用 .build/debug/macvm 走 CLI 主流程。所有虚拟机建在隔离的临时虚拟机目录（MACVM_HOME）里，
# 名字以 verify-tmp- 开头，退出时（含 Ctrl-C）全部关机删除；用户已有的虚拟机一律不碰。
#
# 用法：smoke.sh [cli|linux|qemu|macos|windows|all]...（缺省 cli）；smoke.sh cleanup [目录]
#   cli      不建虚拟机：doctor、ls、错误码与 JSON 外壳（几秒）
#   linux    Debian 13 云镜像，vz 引擎：create/start/wait/exec/cp/ssh/端口转发/挂起恢复/快照/克隆/set
#   qemu     Debian 13 云镜像，qemu 引擎：create/start/wait/exec/agent/stop
#   macos    从用户已有的 macOS 模板新建：start/wait/exec/agent/ui screenshot/stop
#   windows  从用户已有的 Windows 模板新建：同上
#            VERIFY_AGENT_INSTALL=1 时先把模板里的代理换成 .build/guest 里的当前构建
#   cleanup  收掉被强杀后残留的临时虚拟机目录（给了目录时只收这一个），并还原 ssh_config
#
# 证据（每步命令输出、各虚拟机的 run.log、截图）留在 .build/verify/<时间>/。
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)
M="$REPO/.build/debug/macvm"
SSH_CONFIG="$HOME/.config/macvm/ssh_config"
SSH_KEY="$HOME/.config/macvm/id_ed25519"
TMP_PREFIX=".verify-tmp."

EVIDENCE="$REPO/.build/verify/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EVIDENCE"
LOG="$EVIDENCE/smoke.log"
PASS=0
FAIL=0
FAILED_STEPS=""
VM_HOME=""

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

pass() { PASS=$((PASS + 1)); say "  ok    $1"; }

fail() {
    FAIL=$((FAIL + 1))
    FAILED_STEPS="$FAILED_STEPS
  - $1"
    say "  FAIL  $1"
}

# run <步骤名> <命令…>：输出记进日志，结果放在 OUT 与 RC 里。
run() {
    local name=$1; shift
    local start=$SECONDS
    { printf '\n$ %s\n' "$*"; } >>"$LOG"
    OUT=$("$@" 2>&1)
    RC=$?
    printf '%s\n[rc=%s, %ss]\n' "$OUT" "$RC" "$((SECONDS - start))" >>"$LOG"
    STEP="$name (${RC}, $((SECONDS - start))s)"
}

# check <jq 布尔表达式>：对上一步的 OUT 求值。
check() {
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e "$1" >/dev/null 2>&1; then pass "$STEP"; else fail "$STEP"; fi
}

check_rc() { if [ "$RC" -eq "$1" ]; then pass "$STEP"; else fail "$STEP"; fi; }

check_out() {
    if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q -- "$1"; then pass "$STEP"; else fail "$STEP"; fi
}

json_field() { printf '%s' "$OUT" | jq -r "$1" 2>/dev/null; }

preflight() {
    if [ ! -x "$M" ]; then say "找不到 ${M}，先在仓库根目录运行 make sign"; exit 2; fi
    if ! codesign -d --entitlements - "$M" 2>/dev/null | grep -q com.apple.security.virtualization; then
        say "$M 没有 com.apple.security.virtualization，先运行 make sign"; exit 2
    fi
    local newer
    newer=$(cd "$REPO" && find Sources Package.swift -newer "$M" -type f -print 2>/dev/null | head -1)
    if [ -n "$newer" ]; then say "$M 比源码旧（${newer}），先运行 make sign"; exit 2; fi
    command -v jq >/dev/null || { say "需要 PATH 里有 jq 来解析 --json 输出"; exit 2; }
}

# 虚拟机目录放在下载目录里：与云镜像缓存、模板同在一个 APFS 卷上时 create 用 clonefile，一秒内建好；
# 跨卷时要整盘复制 3 GB 的镜像，要几分钟。
download_dir() {
    local d
    d=$(env -u MACVM_HOME "$M" doctor --json | jq -r '.result.downloadPath')
    mkdir -p "$d" && printf '%s' "$d"
}

# create、clone、rm 会按 MACVM_HOME 里的虚拟机列表重写用户的 ssh_config，事先备份、事后整份还原；
# 期间别处对它的改动会被备份覆盖。
# 临时目录里的 owner 记着占用它的进程号和启动时间；进程还在、启动时间也对得上，才算有人在用。
owner_alive() {
    local pid started
    [ -f "$1/owner" ] || return 1
    read -r pid started <"$1/owner" || return 1
    [ -n "$pid" ] && [ "$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1 = $1; print}')" = "$started" ]
}

write_owner() { printf '%s %s\n' "$2" "$(LC_ALL=C ps -o lstart= -p "$2" | awk '{$1 = $1; print}')" >"$1/owner"; }

# 同一台机器同时只跑一份：两份交叠时后开始的那份会把前一份的临时 ssh_config 当原版备份，收尾时写回去。
busy_homes() {
    local home
    for home in "$1"/"$TMP_PREFIX"*; do
        [ -d "$home" ] && owner_alive "$home" && printf '%s\n' "$home"
    done
    return 0
}

begin_vm_home() {
    local busy
    busy=$(busy_homes "$(download_dir)")
    [ -z "$busy" ] || { say "另一份验证正在用 ${busy}，等它跑完再来"; exit 2; }
    VM_HOME=$(mktemp -d "$(download_dir)/${TMP_PREFIX}XXXXXX") || { say "建不了临时虚拟机目录"; exit 2; }
    write_owner "$VM_HOME" "$$"
    export MACVM_HOME="$VM_HOME"
    if [ -f "$SSH_CONFIG" ]; then
        cp -p "$SSH_CONFIG" "$VM_HOME/ssh_config.backup" || { say "备份 $SSH_CONFIG 失败"; exit 2; }
    else
        : >"$VM_HOME/ssh_config.absent"
    fi
    say "临时虚拟机目录：$VM_HOME"
}

# 关掉并删除一个临时目录里的全部虚拟机，还原 ssh_config，再删掉目录；有一步没做成就返回非零。
clean_home() {
    local home=$1 bundle name rc=0
    case "$home" in *"/$TMP_PREFIX"*) ;; *) say "拒绝清理不是临时目录的 $home"; return 1 ;; esac
    [ -d "$home" ] || return 0
    for bundle in "$home"/*.macvm; do
        [ -d "$bundle" ] || continue
        name=$(basename "$bundle" .macvm)
        cp "$bundle/run.log" "$EVIDENCE/$name.run.log" 2>/dev/null
        # 被打断的 suspend、stop 可能还在收尾，虚拟机锁还没放开，rm 报 already_running：隔一秒重试，最多 30 次。
        local _
        for _ in $(seq 1 30); do
            MACVM_HOME="$home" "$M" stop "$name" --force --json >>"$LOG" 2>&1
            MACVM_HOME="$home" "$M" rm "$name" --json >>"$LOG" 2>&1 && break
            sleep 1
        done
        [ -d "$bundle" ] && say "删除 $name 失败，见 $LOG"
    done
    if [ -f "$home/ssh_config.backup" ]; then
        cp -p "$home/ssh_config.backup" "$SSH_CONFIG" || { say "还原 $SSH_CONFIG 失败，备份在 $home/ssh_config.backup"; rc=1; }
    elif [ -f "$home/ssh_config.absent" ]; then
        /bin/rm -f "$SSH_CONFIG" || rc=1
    fi
    if ls "$home"/*.macvm >/dev/null 2>&1; then
        say "仍有虚拟机没删掉，保留 ${home}，手动处理后再运行 smoke.sh cleanup"
        return 1
    fi
    [ "$rc" -eq 0 ] || return 1
    /bin/rm -rf "$home" || { say "删不掉 $home"; return 1; }
}

# 清理失败计入失败项。
end_vm_home() {
    [ -n "$VM_HOME" ] || return 0
    clean_home "$VM_HOME" || fail "清理临时虚拟机目录 $VM_HOME"
    VM_HOME=""
    unset MACVM_HOME
}

on_exit() {
    end_vm_home
    say ""
    say "通过 $PASS 项，失败 $FAIL 项。证据：$EVIDENCE"
    [ "$FAIL" -eq 0 ] || { say "失败的步骤：$FAILED_STEPS"; exit 1; }
}

wait_ready() {
    run "wait $1" "$M" wait "$1" --timeout "${2:-180}" --json
    check '.result.state == "running"'
}

stop_vm() {
    run "stop $1" "$M" stop "$1" --timeout "${2:-90}" --json
    check '.result == {}'
    run "status $1 = stopped" "$M" status "$1" --json
    check '.result.state == "stopped"'
}

free_port() {
    local p _
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        p=$((20000 + RANDOM % 20000))
        nc -z 127.0.0.1 "$p" 2>/dev/null || { printf '%s' "$p"; return; }
    done
    printf '%s' 0
}

flow_cli() {
    say "== cli：不建虚拟机"
    export MACVM_HOME
    MACVM_HOME=$(mktemp -d "${TMPDIR:-/tmp}/macvm-verify-cli.XXXXXX")
    run "--version" "$M" --version
    check_rc 0
    run "doctor" "$M" doctor --json
    check ".result.virtualization == true and (.result.libraryPath | endswith(\"$(basename "$MACVM_HOME")\"))"
    run "ls 为空" "$M" ls --json
    check '.result == []'
    run "status 不存在的虚拟机 → vm_not_found/10" "$M" status verify-tmp-missing --json
    if [ "$RC" -eq 10 ] && [ "$(json_field .error.code)" = vm_not_found ]; then pass "$STEP"; else fail "$STEP"; fi
    run "create 非法名字 → invalid_config/14" "$M" create 'bad/name' --image debian-13 --json
    if [ "$RC" -eq 14 ] && [ "$(json_field .error.code)" = invalid_config ]; then pass "$STEP"; else fail "$STEP"; fi
    run "create 未知镜像 → invalid_config/14" "$M" create verify-tmp-x --image nope --json
    if [ "$RC" -eq 14 ] && [ "$(json_field .error.code)" = invalid_config ]; then pass "$STEP"; else fail "$STEP"; fi
    run "template ls" "$M" template ls --json
    check '.result | type == "array"'
    run "--help 列出退出码" "$M" --help
    check_out "Exit codes"
    if [ -z "$(ls -A "$MACVM_HOME")" ]; then pass "临时目录里没有留下文件"; else fail "临时目录里留下了文件"; fi
    /bin/rm -rf "$MACVM_HOME"
    unset MACVM_HOME
}

flow_linux() {
    say "== linux：Debian 13 云镜像，vz 引擎"
    begin_vm_home
    local n="verify-tmp-$$-linux" c="verify-tmp-$$-clone" port user host_tmp
    port=$(free_port)
    run "create $n" "$M" create "$n" --image debian-13 --cpus 2 --memory 2G --forward "127.0.0.1:$port:22" --json
    check ".result.name == \"$n\" and .result.state == \"stopped\""
    run "start $n" "$M" start "$n" --json
    check '.result.state == "running"'
    wait_ready "$n"
    run "exec uname -m" "$M" exec "$n" -- uname -m
    check_out aarch64
    run "exec 透传退出码 7" "$M" exec "$n" -- sh -c 'exit 7'
    check_rc 7
    # 云镜像首次开机装的是 .build/guest 里的代理，应与当前构建一致。
    run "agent info：代理是当前构建" "$M" agent info "$n" --json
    check '.result.version != null and .result.os == "linux" and .result.updateAvailable != true'
    run "ip" "$M" ip "$n" --json
    check '.result.ipAddress | test("^[0-9.]+$")'

    host_tmp=$(mktemp -d "${TMPDIR:-/tmp}/macvm-verify-cp.XXXXXX")
    printf 'verify %s\n' "$$" >"$host_tmp/in.txt"
    mkdir "$host_tmp/out"
    run "cp 宿主 → 客户机" "$M" cp "$host_tmp/in.txt" "$n:/var/tmp" --json
    check '.result.files == ["/var/tmp/in.txt"]'
    run "cp 客户机 → 宿主" "$M" cp "$n:/var/tmp/in.txt" "$host_tmp/out" --json
    if [ "$RC" -eq 0 ] && cmp -s "$host_tmp/in.txt" "$host_tmp/out/in.txt"; then pass "$STEP"; else fail "$STEP"; fi
    /bin/rm -rf "$host_tmp"

    user=$(jq -r '.guestUser' "$VM_HOME/$n.macvm/config.json")
    run "ssh 经 macvm proxy" ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o "ProxyCommand=\"$M\" proxy $n" "$user@$n" hostname
    check_out "$n"
    run "端口转发 127.0.0.1:$port → 22" sh -c "nc -w 5 127.0.0.1 $port </dev/null | head -c 8"
    check_out "SSH-2.0"

    # Debian 13 的 /tmp 是 tmpfs：标记还在说明是从内存恢复，而不是冷启动。
    run "写内存里的标记" "$M" exec "$n" -- sh -c "echo $$ > /tmp/verify-marker"
    check_rc 0
    run "suspend" "$M" suspend "$n" --json
    check '.result == {}'
    run "status = suspended" "$M" status "$n" --json
    check '.result.state == "suspended"'
    run "start（恢复）" "$M" start "$n" --json
    check '.result.state == "running"'
    wait_ready "$n" 60
    run "恢复后标记还在" "$M" exec "$n" -- cat /tmp/verify-marker
    check_out "$$"
    if grep -q "Resumed from the suspended state" "$VM_HOME/$n.macvm/run.log"; then pass "run.log 记录了恢复"; else fail "run.log 没有 Resumed（见 $n.run.log）"; fi

    run "写快照前的内容" "$M" exec "$n" -- sh -c 'echo v1 > /var/tmp/snap.txt && sync'
    check_rc 0
    stop_vm "$n"
    run "snapshot save" "$M" snapshot save "$n" verify-snap --json
    check '.result.name == "verify-snap"'
    run "snapshot ls" "$M" snapshot ls "$n" --json
    check '[.result[].name] == ["verify-snap"]'
    run "start" "$M" start "$n" --json
    check '.result.state == "running"'
    wait_ready "$n"
    run "改动快照后的内容" "$M" exec "$n" -- sh -c 'echo v2 > /var/tmp/snap.txt && sync'
    check_rc 0
    stop_vm "$n"
    run "snapshot restore" "$M" snapshot restore "$n" verify-snap --json
    check '.result == {}'
    run "start" "$M" start "$n" --json
    check '.result.state == "running"'
    wait_ready "$n"
    run "还原后内容回到 v1" "$M" exec "$n" -- cat /var/tmp/snap.txt
    check_out v1
    stop_vm "$n"
    run "snapshot rm" "$M" snapshot rm "$n" verify-snap --json
    check '.result == {}'

    run "clone" "$M" clone "$n" "$c" --json
    check ".result.name == \"$c\""
    run "set clone --cpus 1 --memory 1G" "$M" set "$c" --cpus 1 --memory 1G --json
    check '.result.cpuCount == 1 and .result.memorySize == 1073741824'
    run "start clone" "$M" start "$c" --json
    check '.result.state == "running"'
    wait_ready "$c"
    # shellcheck disable=SC2016 # 在客户机里展开
    run "clone 换了主机名、按新配置运行" "$M" exec "$c" -- sh -c 'echo "$(hostname) $(nproc)"'
    check_out "$c 1"
    stop_vm "$c"
    run "ls 只有两台临时虚拟机" "$M" ls --json
    check "[.result[].name] | sort == [\"$c\", \"$n\"]"
    end_vm_home
}

flow_qemu() {
    say "== qemu：Debian 13 云镜像，qemu 引擎"
    run "doctor 找得到 QEMU" "$M" doctor --json
    if [ "$(json_field '.result.qemu // empty')" = "" ]; then
        say "  skip  没有 QEMU：make qemu 编译自带的，或 brew install qemu"
        return
    fi
    pass "$STEP"
    begin_vm_home
    local n="verify-tmp-$$-qemu"
    run "create $n --engine qemu" "$M" create "$n" --image debian-13 --engine qemu --cpus 2 --memory 2G --json
    check ".result.name == \"$n\""
    run "start" "$M" start "$n" --json
    check '.result.state == "running"'
    wait_ready "$n"
    run "客户机看到的是 QEMU 机器" "$M" exec "$n" -- cat /sys/class/dmi/id/sys_vendor
    check_out QEMU
    run "agent info" "$M" agent info "$n" --json
    check '.result.version != null'
    stop_vm "$n"
    end_vm_home
}

# flow_template <os>：从用户模板目录里第一个该系统的模板新建，只读模板、不改它。
flow_template() {
    local os=$1 tpl n
    say "== ${os}：从模板新建"
    run "template ls" "$M" template ls --json
    tpl=$(json_field ".result[] | select(.os == \"$os\") | .name" | head -1)
    if [ -z "$tpl" ]; then
        say "  skip  模板目录里没有 $os 模板；完整安装见 SKILL.md 的慢路径"
        return
    fi
    if [ "$os" = macos ]; then
        local running
        running=$(env -u MACVM_HOME "$M" ls --json | jq '[.result[] | select(.os == "macos" and .state == "running")] | length')
        if [ "${running:-0}" -ge 2 ]; then
            say "  skip  已有 $running 台 macOS 虚拟机在运行，系统最多同时运行两台"
            return
        fi
    fi
    if [ "$os" = windows ] && [ "$(env -u MACVM_HOME "$M" doctor --json | jq -r '.result.qemu // empty')" = "" ]; then
        say "  skip  Windows 模板用 qemu 引擎，本机没有 QEMU"
        return
    fi
    begin_vm_home
    n="verify-tmp-$$-$os"
    run "create $n --template $tpl" "$M" create "$n" --template "$tpl" --cpus 4 --memory 8G --json
    check ".result.os == \"$os\""
    run "start" "$M" start "$n" --json
    check '.result.state == "running"'
    wait_ready "$n" 300
    if [ "$os" = macos ]; then
        run "exec sw_vers" "$M" exec "$n" -- sw_vers -productVersion
        check_out '[0-9]'
    else
        run "exec cmd /c echo" "$M" exec "$n" -- cmd /c echo verify-ok
        check_out verify-ok
    fi
    run "agent info" "$M" agent info "$n" --json
    check ".result.os == \"$os\""
    # 模板里是存模板时的旧代理；改了客户机代理时设 VERIFY_AGENT_INSTALL=1，换上 .build/guest 里的再验证。
    if [ "${VERIFY_AGENT_INSTALL:-0}" = 1 ]; then
        run "agent install" "$M" agent install "$n" --json
        check_rc 0
        wait_ready "$n" 300
        run "agent info：代理是当前构建" "$M" agent info "$n" --json
        check ".result.os == \"$os\" and .result.updateAvailable == false"
    fi
    # 截图依赖客户机授权与画面状态，只作证据，不计成败。
    run "ui screenshot（不计成败）" "$M" ui screenshot "$n" "$EVIDENCE/$n.png" --json
    say "  info  $STEP $(json_field '.error.code // .result.path')"
    stop_vm "$n" 120
    end_vm_home
}

# flow_cleanup [目录]：只清理给定的临时目录；不给时清理下载目录里全部的 .verify-tmp.*。
flow_cleanup() {
    say "== cleanup：收掉残留的临时虚拟机目录"
    local d home found=0 rc=0
    if [ $# -gt 0 ]; then
        say "清理 $1"
        clean_home "$1"
        return
    fi
    d=$(env -u MACVM_HOME "$M" doctor --json | jq -r '.result.downloadPath')
    for home in "$d"/"$TMP_PREFIX"*; do
        [ -d "$home" ] || continue
        if owner_alive "$home"; then say "跳过 ${home}：还有验证在用它"; continue; fi
        found=1
        say "清理 $home"
        clean_home "$home" || rc=1
    done
    [ "$found" -eq 1 ] || say "没有残留"
    return $rc
}

trap on_exit EXIT
trap 'exit 130' INT TERM
if [ "${1:-}" = cleanup ]; then
    [ -x "$M" ] || { say "找不到 ${M}，先运行 make sign"; exit 2; }
    shift
    flow_cleanup "$@" || fail "cleanup"
    [ "$FAIL" -eq 0 ]
    exit
fi
preflight
[ $# -gt 0 ] || set -- cli
for flow in "$@"; do
    case "$flow" in
        cli) flow_cli ;;
        linux) flow_linux ;;
        qemu) flow_qemu ;;
        macos | windows) flow_template "$flow" ;;
        all) flow_cli; flow_linux; flow_qemu; flow_template macos; flow_template windows ;;
        *) say "未知流程 ${flow}；可选 cli linux qemu macos windows all，或单独的 cleanup [目录]"; exit 2 ;;
    esac
done
[ "$FAIL" -eq 0 ]
