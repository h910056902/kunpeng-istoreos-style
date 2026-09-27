#!/bin/sh
# ============================================================================
#  kp-portal.sh —— 鲲鹏 C2000 U 「8080 quickstart 内嵌 + 小字开关」补丁器
# ----------------------------------------------------------------------------
#  做三件事（全部幂等，可反复执行）：
#    1) 部署 /www/cgi-bin/portal        （80 端口 nr_webui 门户，弹层内嵌 8080）
#    2) 注入 /overlay/.../quickstart/main.htm  （按 ?kp_small=1 条件隐藏小字）
#    3) 建 /etc/config/kp_portal        （存 ui.hide_small 偏好，默认 0 显示）
#
#  设计约束（踩过的坑，别改）：
#    - 固件**无 base64 / od / openssl / xxd**，二进制/文本只能 heredoc 或 printf 八进制
#    - 固件**无 sftp**，所以安装靠 wget 拉文件 + 本地拼接
#    - busybox ash **不支持 trap ... ERR**，只能用 EXIT
#    - `uci set` **不能新建配置文件**，必须先 `touch /etc/config/<name>`
#    - 幂等锚点一律用 "<!-- KP-...-vN BEGIN/END -->" 注释块，重跑只替换块内容
#
#  回滚：ROLLBACK=1 sh kp-portal.sh     （从 /root/kp-bak-*/ 恢复最近一次备份）
# ============================================================================
set -eu

# ---------------------------------------------------------------------------
# 0. 常量
# ---------------------------------------------------------------------------
MARK_BEGIN='<!-- KP-QUICKSTART-NOSMALLTEXT v1 BEGIN'
MARK_END='KP-QUICKSTART-NOSMALLTEXT v1 END -->'
STAMP="$(date +%Y%m%d_%H%M%S)"
BAKDIR="/root/kp-bak-${STAMP}"

PORTAL_DST='/www/cgi-bin/portal'
MAIN_DST='/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/quickstart/main.htm'
CFG='/etc/config/kp_portal'

# 体积/摘要（用于落盘后自检；与仓库 payload 一致）
PORTAL_MD5='2883e12e4956d9b2bfaa0688c98b2d33'
MAIN_MD5='86586d5345a348601d4a86e138ef0829'

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

ROOTFS="$(mount 2>/dev/null | sed -n 's/.* on \/ .*/\/*/p')"
log "脚本目录 : $SCRIPT_DIR"
log "备份目录 : $BAKDIR"
log "主机名   : $(cat /proc/sys/kernel/hostname 2>/dev/null)"

# 是鲲鹏固件吗？看 portal 或 8080 docroot 是否存在
[ -d '/overlay/nradio-apps' ] || warn "未见 /overlay/nradio-apps —— 可能不是鲲鹏 8080 环境"

# ---------------------------------------------------------------------------
# 2. 回滚模式
# ---------------------------------------------------------------------------
if [ "${ROLLBACK:-0}" = "1" ]; then
	echo "== 回滚模式 =="
	LATEST="$(ls -1d /root/kp-bak-* 2>/dev/null | sort | tail -1)"
	[ -n "$LATEST" ] || die "找不到任何 /root/kp-bak-* 备份"
	log "使用备份 : $LATEST"
	[ -f "$LATEST/portal.bak" ]     && cp -f "$LATEST/portal.bak"     "$PORTAL_DST" && ok "已恢复 portal"
	[ -f "$LATEST/main.htm.bak" ]   && cp -f "$LATEST/main.htm.bak"   "$MAIN_DST"   && ok "已恢复 main.htm"
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
	ok "回滚完成"
	exit 0
fi

# ---------------------------------------------------------------------------
# 3. 准备 payload 源
#    优先用脚本同目录的 payload/（本地/离线安装）；
#    否则从 GitHub raw 拉（一行命令安装）。
# ---------------------------------------------------------------------------
RAW_BASE="${KP_RAW_BASE:-https://raw.githubusercontent.com/h910056902/kunpeng-router-tuning/main/portal-istoreos/payload}"

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
SRC_MAIN=''
for c in "$SCRIPT_DIR/payload/quickstart-main.htm" "$SCRIPT_DIR/quickstart-main.htm"; do
	[ -f "$c" ] && { SRC_MAIN="$c"; break; }
done
SRC_SNIP=''
for c in "$SCRIPT_DIR/payload/quickstart-nosmall.snippet" "$SCRIPT_DIR/quickstart-nosmall.snippet"; do
	[ -f "$c" ] && { SRC_SNIP="$c"; break; }
done

if [ -z "$SRC_PORTAL" ]; then
	log "本地无 payload，从远端拉取…"
	get "$RAW_BASE/portal.lua"             "$TMP/portal.lua" || die "下载 portal.lua 失败"
	SRC_PORTAL="$TMP/portal.lua"
	ok "portal.lua 已下载"
fi

# ---------------------------------------------------------------------------
# 4. 备份现状
# ---------------------------------------------------------------------------
mkdir -p "$BAKDIR"
[ -f "$PORTAL_DST" ] && cp -f "$PORTAL_DST" "$BAKDIR/portal.bak"      && log "备份 portal   → $BAKDIR/portal.bak"
[ -f "$MAIN_DST" ]   && cp -f "$MAIN_DST"   "$BAKDIR/main.htm.bak"    && log "备份 main.htm → $BAKDIR/main.htm.bak"
ok "备份就绪（回滚：ROLLBACK=1 sh $0）"

# ---------------------------------------------------------------------------
# 5. 部署 portal
# ---------------------------------------------------------------------------
echo "== [1/3] 部署 portal =="
cp -f "$SRC_PORTAL" "$PORTAL_DST"
chmod 755 "$PORTAL_DST"
GOT="$(md5of "$PORTAL_DST")"
if [ "$GOT" = "$PORTAL_MD5" ]; then
	ok "portal 校验通过 ($GOT)"
else
	warn "portal md5 = $GOT（预期 $PORTAL_MD5），继续（可能是自定义改动）"
fi

# Lua 语法自检（有 luac 就用，没有则靠运行时）
if command -v luac >/dev/null 2>&1; then
	if luac -p "$PORTAL_DST" 2>/dev/null; then ok "Lua 语法 OK"; else die "Lua 语法错误"; fi
fi

# ---------------------------------------------------------------------------
# 6. 注入 main.htm（幂等：marker 块替换）
# ---------------------------------------------------------------------------
echo "== [2/3] 注入 quickstart/main.htm 小字开关 =="

if [ ! -f "$MAIN_DST" ]; then
	warn "找不到 $MAIN_DST —— 跳过注入（8080 环境可能未安装）"
else
	# 取注入片段：本地优先，否则从已部署 portal 里的常量重建
	if [ -z "$SRC_SNIP" ] && [ -f "$TMP/quickstart-nosmall.snippet" ]; then
		SRC_SNIP="$TMP/quickstart-nosmall.snippet"
	fi
	if [ -z "$SRC_SNIP" ]; then
		# 从远端拉片段
		if get "$RAW_BASE/quickstart-nosmall.snippet" "$TMP/snip"; then
			SRC_SNIP="$TMP/snip"
		fi
	fi

	if [ -z "$SRC_SNIP" ] || [ ! -f "$SRC_SNIP" ]; then
		warn "无注入片段，改用内联 heredoc 生成"
		SRC_SNIP="$TMP/snip-inline"
		cat > "$SRC_SNIP" <<'SNIPEOF'
<!-- KP-QUICKSTART-NOSMALLTEXT v1 BEGIN
     用途：按需隐藏 quickstart SPA 里的「说明小字」。
     触发：URL 带 ?kp_small=1（由 80 端口 portal 弹层的「小字」按钮控制，偏好存 UCI
           /etc/config/kp_portal 的 ui.hide_small）。
     默认：不输出本 <style> —— 保持原厂观感，零副作用。
     注意：!important 必需，因为 SPA 的规则带 [data-v-xxxx] 作用域，特化度更高。
           白名单式枚举，绝不使用 .desc（那是首屏 24px 大字标题）或
           .actioner-tips / .body-tips（弹窗容器，隐藏会让向导整个消失）。 -->
<% if luci.http.formvalue("kp_small") == "1" then %>
<style id="kp-nosmall">
  .subtitle, .cbi-value-description, .cbi-map-descr,
  .module-settings__sub, .module-settings__desc,
  .label-item_tips, .custom-content .tip, .speed_title
    { display: none !important }
</style>
<% end %>
SNIPEOF
	fi

	# ---- 已有 marker → 整块替换；否则锚在 <%+footer%> 之前插入 ----
	TGT="$TMP/main.new"
	if grep -qF "$MARK_BEGIN" "$MAIN_DST"; then
		log "检测到旧注入块 → 整块替换（幂等）"
		# 用 awk 做区间替换：删掉 BEGIN..END，再把新片段插在同一位置
		awk -v beg="$MARK_BEGIN" -v end="$MARK_END" -v snip="$SRC_SNIP" '
			function emit_snip(   line) {
				while ((getline line < snip) > 0) print line
				close(snip)
			}
			index($0, beg) { if (!done) { emit_snip(); done=1 } ; skipping=1; next }
			skipping {
				if (index($0, end)) { skipping=0 }
				next
			}
			{ print }
		' "$MAIN_DST" > "$TGT"
	else
		log "首次注入 → 锚定 <%+footer%> 之前插入"
		if ! grep -qF '<%+footer%>' "$MAIN_DST"; then
			warn "main.htm 里没有 <%+footer%> 锚点 —— 追加到文件末尾"
			cat "$MAIN_DST" "$SRC_SNIP" > "$TGT"
		else
			awk -v snip="$SRC_SNIP" '
				function emit_snip(   line) {
					while ((getline line < snip) > 0) print line
					close(snip)
				}
				{ if (index($0, "<%+footer%>") && !done) { emit_snip(); done=1 } ; print }
			' "$MAIN_DST" > "$TGT"
		fi
	fi

	# 片段末尾补 END 标记（保持 marker 成对，便于下次替换）
	if ! grep -qF "$MARK_END" "$TGT"; then
		cat "$TGT" > "$TGT.2"
		printf '%s\n' "$MARK_END" >> "$TGT.2"
		mv -f "$TGT.2" "$TGT"
	fi

	cp -f "$TGT" "$MAIN_DST"
	ok "main.htm 注入完成（$(wc -c < "$MAIN_DST") 字节）"
fi

# ---------------------------------------------------------------------------
# 7. 建 UCI 配置（记住：必须 touch 再 set）
# ---------------------------------------------------------------------------
echo "== [3/3] 建 $CFG =="
if [ ! -f "$CFG" ]; then
	touch "$CFG"                      # ← 关键：uci set 不能新建文件
	uci set kp_portal.ui=portal
	uci set kp_portal.ui.hide_small='0'   # 默认 0 = 显示
	uci commit kp_portal
	ok "已创建，默认显示（hide_small=0）"
else
	# 已存在：只在字段缺失时补默认值，绝不覆盖用户选择
	uci -q get kp_portal.ui.hide_small >/dev/null 2>&1 || {
		uci set kp_portal.ui=portal
		uci set kp_portal.ui.hide_small='0'
		uci commit kp_portal
		log "补齐缺失字段 hide_small=0"
	}
	ok "已存在，保留现值 hide_small=$(uci -q get kp_portal.ui.hide_small)"
fi

# ---------------------------------------------------------------------------
# 8. 清缓存 + 重启
# ---------------------------------------------------------------------------
rm -f /tmp/luci-indexcache 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || warn "uhttpd 重启失败"

# ---------------------------------------------------------------------------
# 9. 收尾
# ---------------------------------------------------------------------------
echo
ok "安装完成"
echo
echo "  门户入口 : http://192.168.66.1/cgi-bin/portal"
echo "  内嵌页面 : http://192.168.66.1:8080/cgi-bin/luci/admin/quickstart/"
echo "  小字开关 : 弹层右上角按钮（设备级生效，偏好存 UCI）"
echo "  回滚命令 : ROLLBACK=1 sh $0"
echo "  备份位置 : $BAKDIR"
echo
echo "  验证小字隐藏：portal 里点「小字：已显示/已隐藏」切换，"
echo "  或直接访问 .../quickstart/?kp_small=1 看小字是否消失。"
echo
