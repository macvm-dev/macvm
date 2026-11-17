#!/bin/bash
# 在后台构建并启动调试版 App（make run，产物 .build/MacVM.app），虚拟机目录隔离到临时目录，
# 供 cua-operator 在界面里走流程；stop 时收掉临时虚拟机、退出 App，并还原 App 启动时会改动的用户级状态：
# ~/.local/bin/macvm 链接（CLIInstaller）、~/.config/macvm/ssh_config、已装的 macvm 技能副本（SkillInstaller）、
# 未完成的新建记录 creations.json（CreationStore，不跟 MACVM_HOME 走）。
# 进程一律按可执行文件的完整路径认，不碰正式版 /Applications/MacVM.app。
#
# 用法：app.sh start | stop | status
# shellcheck disable=SC1090 # 状态文件由 start 写成 VAR=值 的形式，按路径 source
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)
M="$REPO/.build/debug/macvm"
APP_EXE="$REPO/.build/MacVM.app/Contents/MacOS/MacVM"
STATE_DIR="$REPO/.build/verify/app"
STATE="$STATE_DIR/state"
LINK="$HOME/.local/bin/macvm"
SSH_CONFIG="$HOME/.config/macvm/ssh_config"
CREATIONS="$HOME/Library/Application Support/MacVM/creations.json"
# 备份放在原文件旁、用 CreationStore 不读的文件名，不放进会被 make clean 删掉的 .build。
CREATIONS_BACKUP="$CREATIONS.verify-backup"

die() { printf '%s\n' "$*" >&2; exit 1; }

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# 进程的可执行文件完整路径（lsof 的第一条 txt）。
exe_of() { lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }

is_debug_app() { alive "${1:-}" && [ "$(exe_of "$1")" = "$APP_EXE" ]; }

debug_app_pids() {
    local p
    for p in $(pgrep -x MacVM); do is_debug_app "$p" && printf '%s\n' "$p"; done
}

# 名为 MacVM、但不是调试版的进程（多半是 /Applications 那份）。
other_app_pids() {
    local p
    for p in $(pgrep -x MacVM); do is_debug_app "$p" || printf '%s\n' "$p"; done
}

# 某项还原做完就记进状态文件，stop 重跑时跳过，不重复改用户在两次 stop 之间新写的东西。
mark_done() { printf '%s=done\n' "$1" >>"$STATE"; }

# start 起的 make：命令行是 make run，工作目录是仓库根目录。
is_our_make() {
    alive "${1:-}" || return 1
    case "$(ps -o args= -p "$1" 2>/dev/null)" in "make run" | */make\ run) ;; *) return 1 ;; esac
    [ "$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)" = "$REPO" ]
}

# 与 SkillInstaller.installedCopies 找的位置相同：不是符号链接、里面有 SKILL.md 的 macvm 技能目录。
skill_copies() {
    local d
    for d in "$HOME/.agents/skills/macvm" "$HOME"/.*/skills/macvm "$HOME"/.config/*/skills/macvm; do
        [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/SKILL.md" ] && printf '%s\n' "$d"
    done | sort -u
}

# start 中途失败：先按已记下的状态回滚，再退出。
abort() {
    printf '%s\n' "$*" >&2
    stop >&2 || printf '回滚没做完，状态留在 %s，处理后再运行 app.sh stop\n' "$STATE_DIR" >&2
    exit 1
}

start() {
    [ -f "$STATE" ] && die "上次的状态还在（${STATE}），先 app.sh stop"
    [ -e "$CREATIONS_BACKUP" ] && die "$CREATIONS_BACKUP 还在，是上次没还原的新建记录：确认后挪回 creations.json 或删掉"
    if pgrep -x MacVM >/dev/null; then
        die "已有名为 MacVM 的进程在运行（pid $(pgrep -x MacVM | tr '\n' ' ')），多半是 /Applications 那份：单实例锁会让调试版启动后立即退出。请用户先退出它，或只用 smoke.sh 验证。"
    fi
    [ -x "$M" ] || die "找不到 ${M}，先运行 make sign"

    mkdir -p "$STATE_DIR/skills" || die "建不了 $STATE_DIR"
    local dl home log make_pid app_pid i d
    dl=$(env -u MACVM_HOME "$M" doctor --json | jq -r '.result.downloadPath')
    if [ -z "$dl" ] || ! mkdir -p "$dl"; then die "拿不到下载目录"; fi
    home=$(mktemp -d "$dl/.verify-tmp.XXXXXX") || die "建不了临时虚拟机目录"
    # 状态先落盘，之后每一步失败都能由 stop 回滚。
    {
        printf 'VM_HOME=%q\n' "$home"
        printf 'LINK_TARGET=%q\n' "$(readlink "$LINK" 2>/dev/null)"
    } >"$STATE"

    # 与 smoke.sh 的约定相同：目录里放 ssh_config 的备份，smoke.sh cleanup <目录> 据此还原。
    if [ -f "$SSH_CONFIG" ]; then
        cp -p "$SSH_CONFIG" "$home/ssh_config.backup" || abort "备份 $SSH_CONFIG 失败"
    else
        : >"$home/ssh_config.absent"
    fi

    skill_copies >"$STATE_DIR/skills.list" || abort "列不出已装的技能副本"
    i=0
    while IFS= read -r d; do
        i=$((i + 1))
        if ! ditto "$d" "$STATE_DIR/skills/$i" || ! diff -rq "$d" "$STATE_DIR/skills/$i" >/dev/null; then
            abort "备份技能副本 $d 失败"
        fi
    done <"$STATE_DIR/skills.list"
    printf 'SKILLS_SAVED=1\n' >>"$STATE"

    # 挪开用户的新建记录，调试版看不到也改不到；stop 时挪回。
    if [ -f "$CREATIONS" ]; then
        mv "$CREATIONS" "$CREATIONS_BACKUP" || abort "挪不开 $CREATIONS"
        printf 'CREATIONS_SAVED=1\n' >>"$STATE"
    else
        printf 'CREATIONS_SAVED=0\n' >>"$STATE"
    fi

    log="$STATE_DIR/app.log"
    # 后台的只能是 nohup make 这一条简单命令，$! 才是 make 本身的 pid。
    (cd "$REPO" || exit 1
     MACVM_HOME="$home" nohup make run >"$log" 2>&1 </dev/null &
     echo $! >"$STATE_DIR/make.pid") || abort "进不了 $REPO"
    make_pid=$(cat "$STATE_DIR/make.pid")
    printf 'MAKE_PID=%q\n' "$make_pid" >>"$STATE"

    # make run 先编译客户机程序并组装 App，之后才启动；冷构建要几分钟。
    app_pid=""
    for i in $(seq 1 600); do
        app_pid=$(debug_app_pids | head -1)
        [ -n "$app_pid" ] && break
        alive "$make_pid" || break
        sleep 1
    done
    if [ -z "$app_pid" ]; then
        tail -20 "$log" >&2
        abort "App 没有起来，日志见上"
    fi
    printf 'APP_PID=%q\n' "$app_pid" >>"$STATE"
    # 拿不到单实例锁的进程会在一两秒内退出，确认它还活着。
    for i in 1 2 3; do
        sleep 1
        is_debug_app "$app_pid" || { tail -20 "$log" >&2; abort "App 启动后退出了，日志见上"; }
    done
    printf 'App 已启动：pid %s\n虚拟机目录：%s\n日志：%s\n窗口：进程名 MacVM，可执行文件 %s\n' \
        "$app_pid" "$home" "$log" "$APP_EXE"
}

stop() {
    [ -f "$STATE" ] || { echo "没有在运行的调试版 App"; return 0; }
    APP_PID="" MAKE_PID="" VM_HOME="" LINK_TARGET="" SKILLS_SAVED=0 CREATIONS_SAVED="" CLEANUP="" LINK_RESTORED=""
    . "$STATE"
    local bundle name i d pid pids rc=0

    if [ -n "$VM_HOME" ]; then
        for bundle in "$VM_HOME"/*.macvm; do
            [ -d "$bundle" ] || continue
            name=$(basename "$bundle" .macvm)
            MACVM_HOME="$VM_HOME" "$M" stop "$name" --force --json >/dev/null 2>&1
        done
    fi

    # 只给可执行文件是调试版的进程发信号；状态文件里的 pid 可能已被别的进程复用。
    pids=$( { is_debug_app "$APP_PID" && printf '%s\n' "$APP_PID"; debug_app_pids; } | sort -u)
    for pid in $pids; do is_debug_app "$pid" && kill -TERM "$pid"; done
    is_our_make "$MAKE_PID" && kill -TERM "$MAKE_PID"
    for i in $(seq 1 30); do
        [ -z "$(debug_app_pids)" ] && break
        sleep 1
    done
    for pid in $(debug_app_pids); do kill -KILL "$pid"; done
    for i in $(seq 1 10); do
        [ -z "$(debug_app_pids)" ] && ! is_our_make "$MAKE_PID" && break
        sleep 1
    done
    if [ -n "$(debug_app_pids)" ]; then
        echo "调试版 App 还在运行（pid $(debug_app_pids | tr '\n' ' ')），先不还原用户状态" >&2
        return 1
    fi

    if [ -n "$VM_HOME" ] && [ "$CLEANUP" != "done" ]; then
        if "$SCRIPT_DIR/smoke.sh" cleanup "$VM_HOME" >"$STATE_DIR/cleanup.log" 2>&1; then
            mark_done CLEANUP
        else
            cat "$STATE_DIR/cleanup.log" >&2; echo "临时虚拟机目录没清干净：$VM_HOME" >&2; rc=1
        fi
    fi

    if [ "$LINK_RESTORED" != "done" ]; then
        local link_rc=0
        if [ -n "$LINK_TARGET" ]; then
            if [ "$(readlink "$LINK" 2>/dev/null)" != "$LINK_TARGET" ]; then
                ln -sfn "$LINK_TARGET" "$LINK" || { echo "还原 $LINK 失败" >&2; link_rc=1; }
            fi
        elif [ -L "$LINK" ]; then
            case "$(readlink "$LINK")" in "$REPO"/*) /bin/rm -f "$LINK" || link_rc=1 ;; esac
        fi
        if [ "$link_rc" -eq 0 ]; then mark_done LINK_RESTORED; else rc=1; fi
    fi

    if [ "$SKILLS_SAVED" = 1 ]; then
        local skills_rc=0
        i=0
        while IFS= read -r d; do
            i=$((i + 1))
            if [ ! -f "$STATE_DIR/skills/$i/SKILL.md" ]; then
                echo "技能副本 $d 的备份不见了，没动它" >&2; skills_rc=1; continue
            fi
            diff -rq "$d" "$STATE_DIR/skills/$i" >/dev/null 2>&1 && continue
            { /bin/rm -rf "$d" && ditto "$STATE_DIR/skills/$i" "$d"; } || { echo "还原技能副本 $d 失败" >&2; skills_rc=1; }
        done <"$STATE_DIR/skills.list"
        if [ "$skills_rc" -eq 0 ]; then mark_done SKILLS_SAVED; else rc=1; fi
    fi

    # 正式版在跑时它可能正读写 creations.json，不动它，留给用户退出正式版后再 stop。
    if [ "$CREATIONS_SAVED" = 1 ] || [ "$CREATIONS_SAVED" = 0 ]; then
        if [ -n "$(other_app_pids)" ]; then
            echo "正式版 MacVM 在运行（pid $(other_app_pids | tr '\n' ' ')），creations.json 先不动；退出它后再 app.sh stop" >&2
            rc=1
        elif [ "$CREATIONS_SAVED" = 1 ]; then
            if mv -f "$CREATIONS_BACKUP" "$CREATIONS"; then mark_done CREATIONS_SAVED; else
                echo "还原 $CREATIONS 失败，备份在 $CREATIONS_BACKUP" >&2; rc=1
            fi
        else
            if /bin/rm -f "$CREATIONS"; then mark_done CREATIONS_SAVED; else rc=1; fi
        fi
    fi

    if [ "$rc" -ne 0 ]; then
        echo "没还原干净，状态留在 ${STATE_DIR}，处理后再运行 app.sh stop" >&2
        return 1
    fi
    [ -f "$STATE_DIR/app.log" ] && cp "$STATE_DIR/app.log" "$REPO/.build/verify/app-last.log"
    /bin/rm -rf "$STATE_DIR"
    echo "已退出调试版 App，并还原了 ~/.local/bin/macvm、ssh_config、技能副本与 creations.json；App 日志在 .build/verify/app-last.log"
}

status() {
    [ -f "$STATE" ] || { echo "没有在运行的调试版 App"; return 0; }
    APP_PID="" VM_HOME=""
    . "$STATE"
    if is_debug_app "$APP_PID"; then echo "运行中：pid ${APP_PID}，虚拟机目录 $VM_HOME"; else echo "状态文件还在但调试版 App 不在运行，运行 app.sh stop 收拾"; fi
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    status) status ;;
    *) die "用法：app.sh start | stop | status" ;;
esac
