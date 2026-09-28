#!/bin/sh
# ============================================================================
#  kp-portal.sh —— 鲲鹏 C2000 U 「iStoreOS 风格门户」补丁器  (portal v3)
# ----------------------------------------------------------------------------
#  v3 做了什么（相对 v1.2 的重新规划）：
#    1) 部署 /www/cgi-bin/portal  —— 四卡片 iStoreOS 风格门户
#         · 「istore os风格化」 → 弹层内嵌 8080 iStoreRouter（保留登录鉴权）
#         · 「高级设置」        → 新标签打开 8080 quickstart
#         · 「美化版界面」      → :10086 美化后台
#         · 「官方界面」        → /cgi-bin/luci 原厂 LuCI
#    2) ~~注入 quickstart/main.htm 小字开关~~  —— v3 **已移除**（用户要求先删掉）
#       若设备上仍有旧注入块，可用 KP_CLEAN_NOSMALL=1 清理。
#    3) ~~建 /etc/config/kp_portal~~ —— v3 不再需要 UCI（无小字偏好）
#
#  设计约束（踩过的坑，别改）：
#    - 固件**无 base64 / od / openssl / xxd**，二进制/文本只能 heredoc 或 printf 八进制
#    - 固件**无 sftp**，所以安装靠 wget 拉文件 + 本地拼接
#    - busybox ash **不支持 trap ... ERR**，只能用 EXIT
#    - 幂等锚点一律用 "<!-- KP-...-vN BEGIN/END -->" 注释块
#
#  回滚：ROLLBACK=1 sh kp-portal.sh     （从 /root/kp-bak-*/ 恢复最近一次备份）
# ============================================================================
set -eu

VERSION='3.0'

# ---------------------------------------------------------------------------
# 0. 常量
# ---------------------------------------------------------------------------
STAMP="$(date +%Y%m%d_%H%M%S)"
BAKDIR="/root/kp-bak-${STAMP}"

PORTAL_DST='/www/cgi-bin/portal'
MAIN_DST='/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/quickstart/main.htm'

# portal v3 的 md5（落盘后自检；与仓库 payload 一致）
PORTAL_MD5='9360ce8c9b0421ebb39c11306949861f'

# 旧的「小字开关」注入块 marker（仅用于 KP_CLEAN_NOSMALL=1 时清理）
LEGACY_BEGIN='<!-- KP-QUICKSTART-NOSMALLTEXT v1 BEGIN'

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /tmp)"

log()  { printf '  %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------------------
# 1. 环境自检
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "需要 root 运行"

log "补丁器版本 : v$VERSION (portal v3 / 四卡片)"
log "脚本目录   : $SCRIPT_DIR"
log "备份目录   : $BAKDIR"
log "主机名     : $(cat /proc/sys/kernel/hostname 2>/dev/null)"

[ -d '/overlay/nradio-apps' ] || warn "未见 /overlay/nradio-apps —— 可能不是鲲鹏 8080 环境"

# ---------------------------------------------------------------------------
# 2. 回滚模式
# ---------------------------------------------------------------------------
if [ "${ROLLBACK:-0}" = "1" ]; then
	echo "== 回滚模式 =="
	LATEST="$(ls -1d /root/kp-bak-* 2>/dev/null | sort | tail -1)"
	[ -n "$LATEST" ] || die "找不到任何 /root/kp-bak-* 备份"
	log "使用备份 : $LATEST"
	[ -f "$LATEST/portal.bak" ]   && cp -f "$LATEST/portal.bak"   "$PORTAL_DST" && ok "已恢复 portal"
	[ -f "$LATEST/main.htm.bak" ] && cp -f "$LATEST/main.htm.bak" "$MAIN_DST"   && ok "已恢复 main.htm"
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
	ok "回滚完成"
	exit 0
fi

# ---------------------------------------------------------------------------
# 3. 准备 payload 源（本地优先，否则从 GitHub raw 拉）
# ---------------------------------------------------------------------------
RAW_BASE="${KP_RAW_BASE:-https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/payload}"

get() {  # get <url> <dst>   双栈：curl → wget
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 -o "$2" "$1" && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 15 -O "$2" "$1" && return 0
	fi
	return 1
}

TMP="$(mktemp -d /tmp/kp-portal.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT INT TERM

SRC_PORTAL=''
for c in "$SCRIPT_DIR/payload/portal.lua" "$SCRIPT_DIR/portal.lua"; do
	[ -f "$c" ] && { SRC_PORTAL="$c"; break; }
done

if [ -z "$SRC_PORTAL" ]; then
	log "本地无 payload，从远端拉取…"
	get "$RAW_BASE/portal.lua" "$TMP/portal.lua" || die "下载 portal.lua 失败（检查网络/代理；私有仓库 raw 恒 404）"
	SRC_PORTAL="$TMP/portal.lua"
	ok "portal.lua 已下载"
fi

# ---------------------------------------------------------------------------
# 4. 备份现状
# ---------------------------------------------------------------------------
mkdir -p "$BAKDIR"
[ -f "$PORTAL_DST" ] && cp -f "$PORTAL_DST" "$BAKDIR/portal.bak"   && log "备份 portal   → $BAKDIR/portal.bak"
[ -f "$MAIN_DST" ]   && cp -f "$MAIN_DST"   "$BAKDIR/main.htm.bak" && log "备份 main.htm → $BAKDIR/main.htm.bak"
ok "备份就绪（回滚：ROLLBACK=1 sh $0）"

# ---------------------------------------------------------------------------
# 5. 部署 portal
# ---------------------------------------------------------------------------
echo "== [1/4] 部署 portal（四卡片 iStoreOS 风格）=="
cp -f "$SRC_PORTAL" "$PORTAL_DST"
chmod 755 "$PORTAL_DST"
GOT="$(md5of "$PORTAL_DST")"
if [ "$GOT" = "$PORTAL_MD5" ]; then
	ok "portal 校验通过 ($GOT)"
else
	warn "portal md5 = $GOT（预期 $PORTAL_MD5），继续（可能是自定义改动）"
fi

# Lua 语法自检：优先 luac，其次用 lua 的 loadfile
if command -v luac >/dev/null 2>&1; then
	luac -p "$PORTAL_DST" 2>/dev/null && ok "Lua 语法 OK (luac)" || die "Lua 语法错误"
elif command -v lua >/dev/null 2>&1; then
	R="$(lua -e "local f,e=loadfile('$PORTAL_DST'); print(f and 'OK' or ('FAIL '..tostring(e)))" 2>&1)"
	case "$R" in
		OK) ok "Lua 语法 OK (loadfile)" ;;
		*)  die "Lua 语法错误：$R" ;;
	esac
fi

# ---------------------------------------------------------------------------
# 6. 清理历史「小字开关」注入块（可选）
# ---------------------------------------------------------------------------
echo "== [2/4] 历史小字开关残留 =="
if [ -f "$MAIN_DST" ] && grep -qF "$LEGACY_BEGIN" "$MAIN_DST" 2>/dev/null; then
	if [ "${KP_CLEAN_NOSMALL:-0}" = "1" ]; then
		awk -v beg="$LEGACY_BEGIN" -v end='KP-QUICKSTART-NOSMALLTEXT v1 END -->' '
			index($0, beg) { skipping=1; next }
			skipping { if (index($0, end)) skipping=0; next }
			{ print }
		' "$MAIN_DST" > "$TMP/main.clean"
		cp -f "$TMP/main.clean" "$MAIN_DST"
		ok "已清除旧小字注入块（KP_CLEAN_NOSMALL=1）"
	else
		warn "检测到旧小字注入块 —— v3 门户不会再传 ?kp_small=1，它已失效（无害）"
		log  "如需清除：KP_CLEAN_NOSMALL=1 sh $0"
	fi
else
	ok "无旧注入块（干净）"
fi

# UCI 迁移提示
if [ -f /etc/config/kp_portal ]; then
	warn "存在历史 /etc/config/kp_portal（v3 已不需要）"
	log  "如需移除：rm -f /etc/config/kp_portal && uci -q delete kp_portal"
fi

# ---------------------------------------------------------------------------
# 7. 安装自愈守卫（防 nr_webui 自更新把 portal 覆写回原厂 1.0）
# ---------------------------------------------------------------------------
echo "== [3/4] 安装自愈守卫（kp-portal-guard）=="
GUARD_DST='/usr/bin/kp-portal-guard.sh'
GOLD='/root/kp-portal-gold'

SRC_GUARD=''
for c in "$SCRIPT_DIR/kp-portal-guard.sh" "$SCRIPT_DIR/payload/kp-portal-guard.sh"; do
	[ -f "$c" ] && { SRC_GUARD="$c"; break; }
done
if [ -z "$SRC_GUARD" ]; then
	log "本地无守卫脚本，从远端拉取…"
	get "$RAW_BASE/kp-portal-guard.sh" "$TMP/kp-portal-guard.sh" && SRC_GUARD="$TMP/kp-portal-guard.sh" || warn "守卫脚本拉取失败（跳过守卫安装）"
fi

if [ -n "$SRC_GUARD" ]; then
	cp -f "$SRC_GUARD" "$GUARD_DST"
	chmod 755 "$GUARD_DST"
	# 金样本 = 刚装好的这份
	mkdir -p "$GOLD"
	cp -f "$PORTAL_DST" "$GOLD/portal.v3"
	[ -f "$MAIN_DST" ] && cp -f "$MAIN_DST" "$GOLD/main.htm" || true
	ok "守卫已装 → $GUARD_DST（金样本 $GOLD/portal.v3）"

	# 注册 cron（每分钟自检）
	#   ⚠️ 严禁在 crontab 行里写 $(...) / %（busybox cron 会提前展开 / 转义）
	CRON_LINE='* * * * * /usr/bin/kp-portal-guard.sh >/dev/null 2>&1'
	if crontab -l 2>/dev/null | grep -qF 'kp-portal-guard.sh'; then
		ok "cron 已存在（跳过注册）"
	else
		{ crontab -l 2>/dev/null; echo "$CRON_LINE"; } | crontab -
		/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true
		ok "cron 已注册（每分钟自愈）"
	fi

	# 立即跑一次验证
	"$GUARD_DST" >/dev/null 2>&1 && ok "守卫首次执行 ok" || warn "守卫首次执行异常（见 /var/log/kp-portal-guard.log）"
else
	warn "未安装守卫 —— nr_webui 自更新时 portal 可能被覆写"
fi

# ---------------------------------------------------------------------------
# 8. 清缓存 + 重启
# ---------------------------------------------------------------------------
echo "== [4/4] 清缓存 + 重启 uhttpd =="
rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || warn "uhttpd 重启失败"

# ---------------------------------------------------------------------------
# 9. 收尾 + 自检
# ---------------------------------------------------------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1/cgi-bin/portal' 2>/dev/null || echo '?')"
echo
ok "安装完成（portal v$VERSION）"
echo
echo "  门户入口 : http://192.168.66.1/cgi-bin/portal            [HTTP $CODE]"
echo "  ├ istore os风格化 → 弹层内嵌 http://192.168.66.1:8080/cgi-bin/luci/admin/istorerouter"
echo "  ├ 高级设置        → 新标签  http://192.168.66.1:8080/cgi-bin/luci/admin/quickstart/"
echo "  ├ 美化版界面      → http://192.168.66.1:10086/"
echo "  └ 官方界面        → http://192.168.66.1/cgi-bin/luci"
echo
echo "  回滚命令 : ROLLBACK=1 sh $0"
echo "  备份位置 : $BAKDIR"
echo
echo "  ⚠ 若在【带代理的电脑】上访问 8080 出现 404 Not Found："
echo "     那是代理把 8080 请求转发到了非 8080 端口，被 8080 CGI 的"
echo "     SERVER_PORT 守卫拒绝。请把 192.168.* 加入代理绕过列表，"
echo "     或临时关闭代理。门户的 80 端口不受影响。"
echo
