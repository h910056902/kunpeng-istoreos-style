#!/bin/sh
# ============================================================================
#  install.sh —— 「一行命令」安装入口
# ----------------------------------------------------------------------------
#  用法（设备上，SSH 或 Web 终端）：
#    wget -qO /tmp/kp-portal.sh \
#      https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/install.sh \
#      && sh /tmp/kp-portal.sh
#
#  本脚本只负责「把 kp-portal.sh 拉下来并执行」，自身极简、不碰系统。
#  真正的改动全部集中在 kp-portal.sh，便于审计与回滚。
#
#  环境变量：
#    KP_REF=main          # 指定分支/tag（默认 main）
#    ROLLBACK=1           # 透传给 kp-portal.sh，走回滚
# ============================================================================
set -eu

REPO='h910056902/kunpeng-istoreos-style'
REF="${KP_REF:-main}"
BASE="https://raw.githubusercontent.com/${REPO}/${REF}/portal-istoreos"

log()  { printf '  %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 双栈下载：curl → wget
get() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 -o "$2" "$1" && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 15 -O "$2" "$1" && return 0
	fi
	return 1
}

TMP="$(mktemp -d /tmp/kp-inst.XXXXXX)"
# busybox ash 不支持 ERR 信号，只能 EXIT
trap 'rm -rf "$TMP"' EXIT INT TERM

echo
echo "=========================================="
echo "  鲲鹏 C2000 U · iStoreOS 风格门户 (v3)"
echo "=========================================="
echo

[ "$(id -u)" = "0" ] || die "需要 root 运行（请用 root 登录 SSH）"

log "源 : $BASE"
log "临时目录 : $TMP"
echo

# ---- 拉主脚本 ----
log "下载 kp-portal.sh …"
get "$BASE/kp-portal.sh" "$TMP/kp-portal.sh" || die "下载失败：$BASE/kp-portal.sh（检查网络/代理）"
SIZE="$(wc -c < "$TMP/kp-portal.sh" | tr -d ' ')"
[ "$SIZE" -gt 1000 ] || die "下载内容异常（$SIZE 字节），疑似被劫持/404"
ok "kp-portal.sh 就绪（$SIZE 字节）"

# ---- 拉 payload 与守卫 ----
mkdir -p "$TMP/payload"
for f in portal.lua; do
	if get "$BASE/payload/$f" "$TMP/payload/$f"; then
		ok "payload/$f（$(wc -c < "$TMP/payload/$f" | tr -d ' ') 字节）"
	else
		log "payload/$f 拉取失败 —— 交给 kp-portal.sh 自行兜底"
		rm -f "$TMP/payload/$f"
	fi
done

# 自愈守卫（防 nr_webui 自更新把 portal 覆写回原厂 1.0）
if get "$BASE/kp-portal-guard.sh" "$TMP/kp-portal-guard.sh"; then
	ok "kp-portal-guard.sh（$(wc -c < "$TMP/kp-portal-guard.sh" | tr -d ' ') 字节）"
else
	log "kp-portal-guard.sh 拉取失败 —— 守卫将不安装（门户仍可用，但可能被覆写）"
	rm -f "$TMP/kp-portal-guard.sh"
fi

# ---- 执行（payload 与脚本同目录，会被优先采用）----
echo
sh "$TMP/kp-portal.sh"
