#!/bin/sh
# ============================================================================
#  kp-8080.sh —— 鲲鹏 C2000 U · 8080 LuCI 实例「一键校验 / 按需修复 / 部署」
# ----------------------------------------------------------------------------
#  默认行为 = 只读全量校验 + 打印功能清单（不改动设备任何文件）
#
#    sh kp-8080.sh                      # 只读全量校验
#    sh kp-8080.sh --fix                # 低风险幂等修复（软链 / 清缓存 / uhttpd 开关）
#    KP_DEPLOY=1 sh kp-8080.sh --fix --deploy        # 允许恢复 dispatcher / 私有视图
#    KP_DEPLOY=1 KP_DEPLOY_SHARED=1 sh kp-8080.sh --fix --deploy --controllers
#    KP_DEPLOY=1 sh kp-8080.sh --portal              # 装回 80 口门户 v3（四卡片）
#    sh kp-8080.sh --backup                          # 只做备份
#    sh kp-8080.sh --list                            # 列已有备份
#    ROLLBACK=1 sh kp-8080.sh                        # 从最近备份回滚
#    sh kp-8080.sh --only M-06                       # 只跑某一条判据
#
#  环境变量：KP_REF KP_DIR KP_RAW_BASE KP_DEPLOY KP_DEPLOY_SHARED KP_ON_PC
#            KPUSER KPASS KP_LAN_IP KP_BAK_ROOT
#
#  设计铁律（踩过的坑，别改）：
#   · busybox ash：**无数组**、**无 `trap ... ERR`**（只能 EXIT/HUP/INT/TERM）
#   · 用 `set -u` 但**绝不用 `set -e`** —— `grep -c` 无命中返回 1，加 -e 会误杀整个脚本
#   · 一切判定读**输出值**，不读返回码
#   · 探活必须打 `<LAN>:8080`：实例只绑 LAN，`127.0.0.1:8080` 恒 000
#   · 必须取**正文**断言：模板报错会被 HTTP 200 包着内联进 HTML，只看状态码会漏
#   · 落盘一律「同目录临时名 + mv 原子替换」，**严禁 `cp src dst`**（就地截断）
#   · 改 dispatcher 只需清 indexcache，**不重启 uhttpd**（减少对 80 口扰动）
#   · 判据表按 TAB 分列；busybox `read` 的 IFS 含空白字符，空字段会被折叠，
#     故先经 awk 把空字段补成 '-' 再解析（见 normalize_manifest）
# ============================================================================
set -u

VERSION='1.0.2'   # 1.0.1 真机实测修正：size_of 缺文件不再喷 stderr；WARN 级不误用 [NG]
                  # 1.0.2 真机实测修正：clear_luci_cache 不再误删 80 口的 /tmp/luci-indexcache；
                  #                     C-04 降为人工判据（清缓存无法让"两份一致"成立）

# ---------------------------------------------------------------------------
# 0. 常量与开关
# ---------------------------------------------------------------------------
KP_ROOT="${KP_ROOT:-/overlay/nradio-apps/openwrt-luci-8080}"
DISP="$KP_ROOT/www/cgi-bin/luci"
VIEWROOT="$KP_ROOT/usr/lib/lua/luci/view"
STLDIR="$KP_ROOT/www/luci-static"
CTLDIR='/usr/lib/lua/luci/controller'
PORTAL='/www/cgi-bin/portal'

KPUSER="${KPUSER:-root}"
KPASS="${KPASS:-admin}"
KP_BAK_ROOT="${KP_BAK_ROOT:-/root/kp-8080-bak}"

DISP_MD5='db09b091dd4fe21d61920c8b5f25f8d2'
DISP_SIZE='54998'
PORTAL_MD5='9360ce8c9b0421ebb39c11306949861f'
PORTAL_SIZE='14423'

STAMP="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo manual)"
BAKDIR="$KP_BAK_ROOT/$STAMP"

KP_DIR="${KP_DIR:-$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /tmp)}"
MANIFEST="${KP_MANIFEST:-$KP_DIR/manifest.tsv}"

TMP="$(mktemp -d /tmp/kp8080.XXXXXX 2>/dev/null || echo /tmp/kp8080.$$)"
mkdir -p "$TMP" 2>/dev/null
HTTPDIR="$TMP/http"; mkdir -p "$HTTPDIR"
RESFILE="$TMP/results.tsv"; : > "$RESFILE"

TAB="$(printf '\t')"

MODE_FIX=0; MODE_DEPLOY=0; MODE_CTRL=0; MODE_PORTAL=0
MODE_BACKUP=0; MODE_LIST=0; MODE_QUIET=0; ONLY_ID=''

CNT_PASS=0; CNT_FAIL=0; CNT_WARN=0; CNT_INFO=0; CNT_SKIP=0; CNT_FIXED=0; CNT_BLOCKED=0
NOPROXY=''; LANIP=''; CGIBASE=''; STABASE='http://127.0.0.1:8080'
LOOPBASE='http://127.0.0.1:8080'
JAR="$TMP/cookies.txt"
HAVE_CURL=0
HTTP_OK=1
RESULT=''; ACTUAL=''

# ---------------------------------------------------------------------------
# 1. 输出（ASCII 标记；中文按字节算宽度，emoji/宽字符会错位）
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
	C_G="$(printf '\033[32m')"; C_R="$(printf '\033[31m')"
	C_Y="$(printf '\033[33m')"; C_B="$(printf '\033[36m')"
	C_D="$(printf '\033[2m')"; C_N="$(printf '\033[0m')"
else
	C_G=''; C_R=''; C_Y=''; C_B=''; C_D=''; C_N=''
fi

ok()   { printf "${C_G}[OK]${C_N} %s\n" "$*"; }
no()   { printf "${C_R}[NG]${C_N} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_N} %s\n" "$*"; }
info() { printf "${C_B}[i]${C_N} %s\n" "$*"; }
step() { printf "${C_B}[..]${C_N} %s\n" "$*"; }
dim()  { printf "${C_D}%s${C_N}\n" "$*"; }
sec()  { printf "\n${C_B}== %s ==${C_N}\n" "$*"; }
die()  { printf "${C_R}[NG] %s${C_N}\n" "$*" >&2; exit 1; }

cleanup() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null
	[ -d "${BAKDIR:-/nonexistent}" ] && printf "${C_D}  备份保留在: %s${C_N}\n" "$BAKDIR"
	return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
	cat <<EOF
kp-8080.sh v$VERSION —— 8080 LuCI 实例 校验 / 修复 / 部署

用法：sh kp-8080.sh [选项]

  (无选项)            只读全量校验 + 打印功能清单（默认）
  --fix               低风险幂等修复（软链 / 清缓存 / uhttpd.openwrt8080.enabled）
  --deploy            允许恢复 dispatcher 与私有视图（需 KP_DEPLOY=1）
  --controllers       允许恢复 3 个共享控制器（需 KP_DEPLOY_SHARED=1；80 口共用）
  --portal            装回 80 口门户 v3 四卡片
  --backup            只做备份
  --list              列已有备份
  --only <id>         只处理某一条判据（如 --only M-06）
  --quiet             安静模式

环境变量：
  KP_REF  KP_DIR  KP_RAW_BASE  KP_DEPLOY=1  KP_DEPLOY_SHARED=1  KP_ON_PC=1
  KPUSER / KPASS（默认 root/admin，不会写入日志与备份）
  KP_LAN_IP  KP_BAK_ROOT  ROLLBACK=1
EOF
}

# ---------------------------------------------------------------------------
# 2. 工具
# ---------------------------------------------------------------------------
has()   { command -v "$1" >/dev/null 2>&1; }
md5of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
size_of() {
	# ⚠ 必须先判 -f：curl 在"连接被拒"(127.0.0.1:8080 恒拒)时**不会创建** -o 目标文件，
	#   裸 `wc -c < 不存在` 会把 `can't open ...: no such file` 打到 stderr，
	#   污染报告并让前后两次运行 diff 变脏（实测踩到）。
	[ -f "$1" ] || { printf '0'; return 0; }
	wc -c < "$1" 2>/dev/null | tr -d ' '
}
fingerprint() { [ -f "$1" ] && printf '%s:%s' "$(size_of "$1")" "$(md5of "$1")" || printf 'MISSING'; }
slug()  { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
need_root() { [ "$(id -u 2>/dev/null)" = "0" ] || die "需要 root 运行（请用 root 登录 SSH）"; }
is_device() {
	[ -d "$KP_ROOT" ] || return 1
	[ -n "$(uci -q get uhttpd.openwrt8080 2>/dev/null)" ] || return 1
	return 0
}

lan_ip() {
	[ -n "${KP_LAN_IP:-}" ] && { printf '%s' "$KP_LAN_IP"; return; }
	_ip=$(uci -q get uhttpd.openwrt8080.listen_http 2>/dev/null | awk -F: '{print $1}')
	case "$_ip" in ""|\$*|0.0.0.0|'[::]') _ip=$(uci -q get network.lan.ipaddr 2>/dev/null) ;; esac
	case "$_ip" in ""|\$*|0.0.0.0|'[::]') _ip=$(ip -4 addr show br-lan 2>/dev/null | grep -m1 -oE 'inet [0-9.]+' | awk '{print $2}') ;; esac
	printf '%s' "$_ip"
}

fetch() {  # <url> <dst>
	[ "$HAVE_CURL" = 1 ] && { curl -fsSL --connect-timeout 10 $NOPROXY -o "$2" "$1" 2>/dev/null && return 0; }
	has wget && { wget -q -T 15 -O "$2" "$1" 2>/dev/null && return 0; }
	return 1
}

fetch_checked() {  # <url> <dst> <minbytes> [md5]
	fetch "$1" "$2" || return 1
	_fs=$(size_of "$2"); [ -z "$_fs" ] && _fs=0
	[ "$_fs" -ge "$3" ] || { rm -f "$2"; return 1; }
	[ -n "${4:-}" ] && { [ "$(md5of "$2")" = "$4" ] || { rm -f "$2"; return 1; }; }
	return 0
}

resolve_payload() {  # <rel>
	for _c in "$KP_DIR/payload/$1" "${KP_PAYLOAD_DIR:-/nonexistent}/payload/$1" "$KP_DIR/$1"; do
		[ -f "$_c" ] && { printf '%s' "$_c"; return 0; }
	done
	printf '%s' "$KP_DIR/payload/$1"
}

ensure_payload() {  # <rel> <minbytes> [md5]
	_p="$(resolve_payload "$1")"
	[ -f "$_p" ] && { printf '%s' "$_p"; return 0; }
	[ -n "${KP_RAW_BASE:-}" ] || return 1
	_d="$TMP/payload/$1"; mkdir -p "$(dirname "$_d")" 2>/dev/null
	fetch_checked "$KP_RAW_BASE/payload/$1" "$_d" "$2" "${3:-}" || return 1
	printf '%s' "$_d"; return 0
}

# ---------------------------------------------------------------------------
# 3. HTTP / 鉴权
# ---------------------------------------------------------------------------
login() {
	[ "$HAVE_CURL" = 1 ] || return 1
	rm -f "$JAR"
	curl -s $NOPROXY -c "$JAR" -o /dev/null -m 12 "$CGIBASE/admin/status/details" 2>/dev/null
	curl -s $NOPROXY -b "$JAR" -c "$JAR" -o /dev/null -m 12 -X POST \
		"$CGIBASE/admin/status/details" \
		-d "luci_username=$KPUSER" -d "luci_password=$KPASS" 2>/dev/null
	grep -q 'sysauth' "$JAR" 2>/dev/null
}

cached_get() {  # <url>  → K_CODE / K_SIZE / K_BODY
	_s="$(slug "$1")"
	K_BODY="$HTTPDIR/$_s.body"
	if [ -f "$HTTPDIR/$_s.code" ]; then
		K_CODE="$(cat "$HTTPDIR/$_s.code" 2>/dev/null)"
		K_SIZE="$(size_of "$K_BODY")"
		return 0
	fi
	_b=1
	case "$1" in "$LOOPBASE"/*) _b=0 ;; esac
	if [ "$HAVE_CURL" = 1 ]; then
		if [ "$_b" = 1 ] && [ -s "$JAR" ]; then
			K_CODE="$(curl -s $NOPROXY -b "$JAR" -o "$K_BODY" -w '%{http_code}' -m 12 "$1" 2>/dev/null)"
		else
			K_CODE="$(curl -s $NOPROXY -o "$K_BODY" -w '%{http_code}' -m 12 "$1" 2>/dev/null)"
		fi
	elif has wget; then
		wget -q -O "$K_BODY" -T 12 "$1" 2>/dev/null
		K_CODE="$(wget -qS -O /dev/null -T 12 "$1" 2>&1 | awk '/HTTP\//{print $2; exit}')"
	else
		K_CODE=000
	fi
	[ -z "${K_CODE:-}" ] && K_CODE=000
	printf '%s' "$K_CODE" > "$HTTPDIR/$_s.code"
	K_SIZE="$(size_of "$K_BODY")"
	return 0
}

body_has() { grep -qE -- "$1" "$K_BODY" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 4. 判定原语
# ---------------------------------------------------------------------------
count_anchored() { _n=$(grep -cE -- "$2" "$1" 2>/dev/null); [ -z "$_n" ] && _n=0; printf '%s' "$_n"; }
count_fixed()    { _n=$(grep -cF -- "$2" "$1" 2>/dev/null); [ -z "$_n" ] && _n=0; printf '%s' "$_n"; }
first_line()     { grep -nE -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }

symlink_actual() {  # <path> → 规范化目标（非软链输出空）
	[ -L "$1" ] || { printf ''; return 0; }
	_t="$(readlink "$1" 2>/dev/null)"
	[ -z "$_t" ] && { printf ''; return 0; }
	case "$_t" in
		/*) printf '%s' "$_t" ;;
		*)  printf '%s/%s' "$(dirname "$1")" "$_t" ;;
	esac
}

norm_target() {  # <path> <target>
	case "$2" in
		/*) printf '%s' "$2" ;;
		*)  printf '%s/%s' "$(dirname "$1")" "$2" ;;
	esac
}

# ---------------------------------------------------------------------------
# 5. LuCI 缓存 / 语法 / 原子落位
# ---------------------------------------------------------------------------
clear_luci_cache() {
	# ⚠ 只清 8080 自己的索引缓存（dispatcher 里 indexcache = /tmp/luci-indexcache-bootstrap）。
	#   **绝不碰 /tmp/luci-indexcache** —— 那是 80 口的缓存，清它等于让 80 口首次访问变慢，
	#   违反"只动 openwrt-luci-8080/**、不扰动 80 口"的隔离原则。
	rm -f /tmp/luci-indexcache-bootstrap 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	rm -f "$KP_ROOT"/usr/lib/lua/luci/*.luac 2>/dev/null
	return 0
}

lua_syntax_check() {  # <file> → 0=OK
	has luac && { luac -p "$1" >/dev/null 2>&1 && return 0 || return 1; }
	has lua || return 0
	_r="$(lua -e "local f,e=loadfile('$1'); if f then io.write('OK') else io.write(tostring(e)) end" 2>&1)"
	case "$_r" in
		OK) return 0 ;;
		*)  printf '%s\n' "$_r" >&2; return 1 ;;
	esac
}

atomic_install() {  # <src> <dst> <mode>
	_src="$1"; _dst="$2"; _mode="${3:-644}"
	_dd="$(dirname "$_dst")"
	[ -d "$_dd" ] || return 1
	_tmp="$_dd/.kpnew.$$.$(basename "$_dst")"
	cp -f "$_src" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
	chmod "$_mode" "$_tmp" 2>/dev/null
	mv -f "$_tmp" "$_dst" 2>/dev/null || { rm -f "$_tmp"; return 1; }
	[ "$(md5of "$_dst")" = "$(md5of "$_src")" ] || return 1
	return 0
}

# ---------------------------------------------------------------------------
# 6. 备份 / 回滚
# ---------------------------------------------------------------------------
backup_begin() {
	[ -d "$BAKDIR" ] && return 0
	mkdir -p "$BAKDIR" 2>/dev/null || die "无法创建备份目录 $BAKDIR"
	chmod 700 "$BAKDIR" 2>/dev/null
	: > "$BAKDIR/MANIFEST"
	return 0
}

backup_file() {  # <src> <relname>
	[ -f "$1" ] || return 0
	backup_begin
	mkdir -p "$BAKDIR/$(dirname "$2")" 2>/dev/null
	cp -p "$1" "$BAKDIR/$2" 2>/dev/null || return 1
	printf '%s\t%s\t%s\n' "$2" "$(md5of "$1")" "$(ls -l "$1" 2>/dev/null | awk '{print $1}')" >> "$BAKDIR/MANIFEST"
	return 0
}

do_backup() {
	sec "备份 8080 实例"
	backup_begin
	backup_file "$DISP" "dispatcher.luci" && ok "dispatcher.luci"
	if [ -d "$VIEWROOT" ]; then
		tar -czf "$BAKDIR/views.tar.gz" -C "$KP_ROOT/usr/lib/lua/luci" view 2>/dev/null \
			&& ok "views.tar.gz（$(size_of "$BAKDIR/views.tar.gz") B）" || warn "视图打包失败"
	fi
	for _c in istorerouter.lua quickstart.lua systools.lua; do
		backup_file "$CTLDIR/$_c" "controllers/$_c" && ok "controllers/$_c"
	done
	backup_file "$PORTAL" "portal" && ok "portal"
	uci show uhttpd > "$BAKDIR/uhttpd.uci" 2>/dev/null && ok "uhttpd.uci"
	if [ -f "$BAKDIR/views.tar.gz" ]; then
		tar -tzf "$BAKDIR/views.tar.gz" >/dev/null 2>&1 || die "views.tar.gz 损坏，中止"
	fi
	echo
	ok "备份完成: $BAKDIR"
	dim "  条目 $(ls -1 "$BAKDIR" 2>/dev/null | wc -l | tr -d ' ') 个  MANIFEST $(wc -l < "$BAKDIR/MANIFEST" 2>/dev/null | tr -d ' ') 行"
}

list_backups() {
	sec "已有备份（$KP_BAK_ROOT）"
	if [ -d "$KP_BAK_ROOT" ]; then ls -1 "$KP_BAK_ROOT" 2>/dev/null | sort; else warn "尚无备份目录"; fi
}

do_rollback() {
	sec "回滚"
	_lb="$(ls -1d "$KP_BAK_ROOT"/* 2>/dev/null | sort | tail -1)"
	[ -n "$_lb" ] || die "找不到任何 $KP_BAK_ROOT/* 备份"
	[ -f "$_lb/MANIFEST" ] || die "备份缺 MANIFEST，拒绝猜测式回滚: $_lb"
	info "使用备份: $_lb"
	[ -f "$_lb/dispatcher.luci" ] && atomic_install "$_lb/dispatcher.luci" "$DISP" 755 && ok "已恢复 dispatcher"
	[ -f "$_lb/views.tar.gz" ] && tar -xzf "$_lb/views.tar.gz" -C "$KP_ROOT/usr/lib/lua/luci" 2>/dev/null && ok "已恢复私有视图"
	for _c in istorerouter.lua quickstart.lua systools.lua; do
		[ -f "$_lb/controllers/$_c" ] && atomic_install "$_lb/controllers/$_c" "$CTLDIR/$_c" 644 && ok "已恢复 controllers/$_c"
	done
	[ -f "$_lb/portal" ] && atomic_install "$_lb/portal" "$PORTAL" 755 && ok "已恢复 portal"
	clear_luci_cache
	ok "回滚完成（缓存已清）"
}

# ---------------------------------------------------------------------------
# 7. 部署（高风险；护栏见头注释）
# ---------------------------------------------------------------------------
assert_dispatch_contract() {  # <newfile>
	[ -f "$1" ] || { no "契约断言：文件不存在"; return 1; }
	_sz=$(size_of "$1")
	[ "$_sz" -ge 50000 ] || { no "契约断言失败：size=$_sz < 50000"; return 1; }
	_ln=$(wc -l < "$1" | tr -d ' ')
	[ "$_ln" -ge 1400 ] || { no "契约断言失败：行数=$_ln < 1400"; return 1; }
	[ "$(count_anchored "$1" '^if os[.]getenv[(]"SERVER_PORT"[)] ~= "8080" then$')" = "1" ] \
		|| { no "契约断言失败：SERVER_PORT 守卫 != 1"; return 1; }
	[ "$(count_anchored "$1" '^luci[.]dispatcher[.]indexcache = "/tmp/luci-indexcache-bootstrap"$')" = "1" ] \
		|| { no "契约断言失败：indexcache 隔离行 != 1"; return 1; }
	ok "契约断言通过（size=$_sz 行数=$_ln 守卫=1 indexcache=1）"
	return 0
}

probe_ir() {  # 探测 8080 关键页；回填 PROBE_CODE
	rm -f "$HTTPDIR"/* 2>/dev/null
	[ "$HAVE_CURL" = 1 ] && login
	cached_get "$CGIBASE/admin/istorerouter"
	PROBE_CODE="$K_CODE"
	PROBE_ISE=0
	body_has 'Internal Server Error' && PROBE_ISE=1
	return 0
}

deploy_dispatcher() {
	_src="$(ensure_payload dispatcher.luci 50000 "$DISP_MD5")" || { no "无法取得 dispatcher payload"; return 1; }
	if [ "$(fingerprint "$DISP")" = "$DISP_SIZE:$DISP_MD5" ]; then
		ok "dispatcher 已就绪（$DISP_SIZE:$DISP_MD5），跳过"; return 3
	fi
	warn "dispatcher 原指纹 = $(fingerprint "$DISP")（期望 $DISP_SIZE:$DISP_MD5）"
	step "Lua 语法校验"
	lua_syntax_check "$_src" || { no "语法校验失败，拒绝落盘（系统 0 改动）"; return 1; }
	ok "Lua 语法 OK"
	step "契约断言（在新文件上预演）"
	assert_dispatch_contract "$_src" || { no "契约不达标，拒绝落盘（系统 0 改动）"; return 1; }
	step "备份 → 同目录原子落位"
	backup_file "$DISP" "dispatcher.luci" || { no "备份失败，中止"; return 1; }
	atomic_install "$_src" "$DISP" 755 || { no "落位失败"; return 1; }
	ok "dispatcher 已恢复 $(fingerprint "$DISP")"
	clear_luci_cache
	step "探活 admin/istorerouter"
	probe_ir
	if [ "$PROBE_CODE" = 200 ] && [ "$PROBE_ISE" = 0 ]; then
		ok "探活通过（200，无内联 500）"
		[ -f "$BAKDIR/dispatcher.luci" ] || cp -p "$_src" "$BAKDIR/dispatcher.luci" 2>/dev/null
		return 0
	fi
	no "探活失败（code=$PROBE_CODE ISE=$PROBE_ISE），自动回滚"
	[ -f "$BAKDIR/dispatcher.luci" ] && atomic_install "$BAKDIR/dispatcher.luci" "$DISP" 755
	clear_luci_cache
	return 1
}

deploy_view() {  # <rel>
	_rel="$1"
	_p="$(ensure_payload "views/$_rel" 1)" || { no "无法取得 views/$_rel"; return 1; }
	_dst="$VIEWROOT/$_rel"
	_psz=$(size_of "$_p"); _pmd=$(md5of "$_p")
	if [ -f "$_dst" ] && [ "$(size_of "$_dst")" = "$_psz" ] && [ "$(md5of "$_dst")" = "$_pmd" ]; then
		ok "views/$_rel 已就绪，跳过"; return 3
	fi
	backup_file "$_dst" "views/$_rel"
	mkdir -p "$(dirname "$_dst")" 2>/dev/null
	atomic_install "$_p" "$_dst" 644 || { no "views/$_rel 落位失败"; return 1; }
	clear_luci_cache
	ok "views/$_rel 已恢复（$_psz B）"
	return 0
}

deploy_controller() {  # <rel>
	_rel="$1"
	_p="$(ensure_payload "shared-controller/$_rel" 1)" || { no "无法取得 shared-controller/$_rel"; return 1; }
	_dst="$CTLDIR/$_rel"
	if [ -f "$_dst" ] && [ "$(md5of "$_dst")" = "$(md5of "$_p")" ]; then
		ok "controllers/$_rel 已就绪，跳过"; return 3
	fi
	step "语法校验 controllers/$_rel"
	lua_syntax_check "$_p" || { no "语法失败，拒绝落盘"; return 1; }
	backup_file "$_dst" "controllers/$_rel"
	atomic_install "$_p" "$_dst" 644 || { no "controllers/$_rel 落位失败"; return 1; }
	clear_luci_cache
	ok "controllers/$_rel 已恢复"
	probe_ir
	if [ "$PROBE_CODE" != 200 ]; then
		no "8080 侧探活失败（$PROBE_CODE），回滚 controllers/$_rel"
		[ -f "$BAKDIR/controllers/$_rel" ] && atomic_install "$BAKDIR/controllers/$_rel" "$_dst" 644
		clear_luci_cache
		return 1
	fi
	warn "8080 侧 200；80 口为共享目录，请人工确认 80 端口界面正常"
	return 0
}

install_portal() {
	[ -n "${KP_RAW_BASE:-}" ] || { no "无 KP_RAW_BASE，无法拉取门户安装器"; return 1; }
	_pd="$TMP/portal-istoreos"; mkdir -p "$_pd/payload" 2>/dev/null
	_pbase="$(printf '%s' "$KP_RAW_BASE" | sed 's#/8080$#/portal-istoreos#')"
	step "下载门户补丁器与 payload"
	fetch_checked "$_pbase/kp-portal.sh" "$_pd/kp-portal.sh" 1000 || { no "下载 kp-portal.sh 失败"; return 1; }
	fetch_checked "$_pbase/payload/portal.lua" "$_pd/payload/portal.lua" 10000 "$PORTAL_MD5" \
		|| { no "portal.lua 下载失败或 md5 不符"; return 1; }
	ok "门户物料就绪"
	step "执行门户补丁器"
	sh "$_pd/kp-portal.sh" || { no "门户补丁器失败"; return 1; }
	_fp="$(fingerprint "$PORTAL")"
	if [ "$_fp" = "$PORTAL_SIZE:$PORTAL_MD5" ]; then
		ok "门户 v3 已就位（$_fp）"; return 0
	fi
	warn "门户指纹 = $_fp（期望 $PORTAL_SIZE:$PORTAL_MD5）"
	[ "$_fp" = "$PORTAL_SIZE:$PORTAL_MD5" ]
}

# ---------------------------------------------------------------------------
# 8. 判定分派（回填 RESULT / ACTUAL）
# ---------------------------------------------------------------------------
kind_filehash() {
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_es="${expect%%:*}"; _em="${expect#*:}"
	_asz="$(size_of "$subject")"; _amd="$(md5of "$subject")"
	ACTUAL="$_asz:$_amd"
	_ok=1
	[ "$_es" != '-' ] && [ "$_asz" != "$_es" ] && _ok=0
	[ "$_em" != '-' ] && [ "$_amd" != "$_em" ] && _ok=0
	if [ "$_ok" = 1 ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_fileexists() {
	if [ -f "$subject" ]; then RESULT=PASS; ACTUAL='present'; else RESULT="$level"; ACTUAL='missing'; fi
	return 0
}

kind_dir() {
	if [ -d "$subject" ]; then RESULT=PASS; ACTUAL='dir'; else RESULT="$level"; ACTUAL='no-dir'; fi
	return 0
}

kind_dircount() {
	if [ ! -d "$subject" ]; then RESULT="$level"; ACTUAL='no-dir'; return 0; fi
	_n=$(ls -1 "$subject" 2>/dev/null | wc -l | tr -d ' ')
	ACTUAL="$_n 个子目录（期望 $expect）"
	if [ "$_n" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_text_count() {
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_n=$(count_anchored "$subject" "$pattern")
	ACTUAL="$_n（期望 $expect）"
	if [ "$_n" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

derive_end_anchor() {  # <open-anchor> —— 由 BEGIN→END / START→END 派生闭锚点
	# ⚠ 必须【锚定行尾】替换：KP-QUICKSTART-* 里的 "QUICKSTART" 含子串 "START"，
	#   早期用 `sed -e 's/BEGIN/END/' -e 's/START/END/'` 会把 QUICKSTART 改成
	#   QUICK-END（实测 4 个族的 close 恒为 0）。故先摘掉尾部 '$'，再用 BEGIN$/START$ 锚定。
	_a="$1"; _tail=''
	case "$_a" in
		*'$') _tail='$'; _a="${_a%?}" ;;
	esac
	_e="$(printf '%s' "$_a" | sed 's/BEGIN$/END/')"
	[ "$_e" = "$_a" ] && _e="$(printf '%s' "$_a" | sed 's/START$/END/')"
	printf '%s%s' "$_e" "$_tail"
}

kind_pair() {  # pattern=开锚点；由 BEGIN→END / START→END 派生闭锚点
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_o="$pattern"
	_e="$(derive_end_anchor "$_o")"
	[ "$_e" = "$_o" ] && { RESULT="$level"; ACTUAL='锚点无 BEGIN/START，无法派生 END'; return 0; }
	_no=$(count_anchored "$subject" "$_o")
	_ne=$(count_anchored "$subject" "$_e")
	ACTUAL="open=$_no close=$_ne（期望各 $expect）"
	if [ "$_no" = "$expect" ] && [ "$_ne" = "$expect" ]; then
		_bl="$(first_line "$subject" "$_o")"; _el="$(first_line "$subject" "$_e")"
		[ -n "$_bl" ] && [ -n "$_el" ] && ACTUAL="$ACTUAL L$_bl-L$_el"
		RESULT=PASS
	else
		RESULT="$level"
	fi
	return 0
}

kind_substr() {
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_n=$(count_fixed "$subject" "$pattern")
	ACTUAL="$_n（期望 $expect）"
	if [ "$_n" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_symlink() {
	_got="$(symlink_actual "$subject")"
	_want="$(norm_target "$subject" "$pattern")"
	if [ -n "$_got" ] && [ "$_got" = "$_want" ]; then
		if [ -e "$subject" ]; then RESULT=PASS; ACTUAL="-> $_got"
		else RESULT="$level"; ACTUAL="-> $_got [目标悬空]"; fi
	elif [ -z "$_got" ]; then
		RESULT="$level"; ACTUAL="非软链/不存在（期望 -> $_want）"
	else
		RESULT="$level"; ACTUAL="-> $_got（期望 -> $_want）"
	fi
	return 0
}

kind_menu_node() {
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_n=$(count_anchored "$subject" "$pattern")
	ACTUAL="$_n（期望 $expect）"
	if [ "$_n" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_http_code() {
	cached_get "$CGIBASE/$subject"
	ACTUAL="$K_CODE ${K_SIZE}B"
	if [ "$K_CODE" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_http_body() {
	cached_get "$CGIBASE/$subject"
	if [ "$pattern" = 'F' ]; then
		if body_has "$expect"; then RESULT="$level"; ACTUAL="正文含『$expect』（不应出现）"
		else RESULT=PASS; ACTUAL='未出现'; fi
	else
		if body_has "$expect"; then RESULT=PASS; ACTUAL='命中'
		else RESULT="$level"; ACTUAL="正文未见『$expect』（code=$K_CODE）"; fi
	fi
	return 0
}

kind_static_code() {
	cached_get "$STABASE$subject"
	ACTUAL="$K_CODE ${K_SIZE}B"
	if [ "$K_CODE" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_uci_get() {
	_got="$(uci -q get "$subject" 2>/dev/null)"
	_want="$expect"
	case "$_want" in *'@{LAN}'*) _want="$(printf '%s' "$_want" | sed "s/@{LAN}/$LANIP/")" ;; esac
	if [ "$_got" = "$_want" ]; then RESULT=PASS; ACTUAL="$_got"
	else RESULT="$level"; ACTUAL="$_got（期望 $_want）"; fi
	return 0
}

kind_cache_pair() {
	_a=/tmp/luci-indexcache; _b=/tmp/luci-indexcache-bootstrap
	_ha=0; _hb=0
	[ -f "$_a" ] && _ha=1
	[ -f "$_b" ] && _hb=1
	if [ "$_ha" = 0 ] || [ "$_hb" = 0 ]; then
		RESULT="$level"; ACTUAL="缺文件（80=$_ha 8080=$_hb）"; return 0
	fi
	_sa=$(size_of "$_a"); _sb=$(size_of "$_b")
	if [ "$_sa" = "$_sb" ]; then RESULT=PASS; ACTUAL="两份均 ${_sa}B"
	else RESULT="$level"; ACTUAL="$_sa vs $_sb（大小不一致）"; fi
	return 0
}

kind_loopback_code() {
	cached_get "$LOOPBASE$subject"
	ACTUAL="$K_CODE"
	if [ "$K_CODE" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_portal_card_count() {
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_n=$(count_fixed "$subject" "$pattern")
	ACTUAL="$_n（期望 $expect）"
	if [ "$_n" = "$expect" ]; then RESULT=PASS; else RESULT="$level"; fi
	return 0
}

kind_portal_body() {
	[ -f "$subject" ] || { RESULT="$level"; ACTUAL='MISSING'; return 0; }
	_tb="$TMP/portal.render"
	[ "$HAVE_CURL" = 1 ] && curl -s $NOPROXY -H "Host: $LANIP" -o "$_tb" -m 12 \
		"http://127.0.0.1/cgi-bin/portal" 2>/dev/null
	[ -s "$_tb" ] || cp -f "$subject" "$_tb" 2>/dev/null
	if grep -qF -- "$expect" "$_tb" 2>/dev/null; then RESULT=PASS; ACTUAL='命中'
	else RESULT="$level"; ACTUAL="渲染后未见『$expect』"; fi
	return 0
}

dispatch_kind() {
	RESULT=''; ACTUAL=''
	case "$kind" in
		filehash)          kind_filehash ;;
		fileexists)        kind_fileexists ;;
		dir)               kind_dir ;;
		dircount)          kind_dircount ;;
		text_count)        kind_text_count ;;
		pair)              kind_pair ;;
		substr)            kind_substr ;;
		symlink)           kind_symlink ;;
		menu_node)         kind_menu_node ;;
		http_code)         kind_http_code ;;
		http_body)         kind_http_body ;;
		static_code)       kind_static_code ;;
		uci_get)           kind_uci_get ;;
		cache_pair)        kind_cache_pair ;;
		loopback_code)     kind_loopback_code ;;
		portal_card_count) kind_portal_card_count ;;
		portal_body)       kind_portal_body ;;
		*)                 RESULT='INFO'; ACTUAL="未知 kind: $kind" ;;
	esac
	[ -z "$RESULT" ] && RESULT='INFO'
	[ -z "$ACTUAL" ] && ACTUAL='-'
	return 0
}

# ---------------------------------------------------------------------------
# 9. 修复分派
# ---------------------------------------------------------------------------
fix_symlink() {  # <name>|<target>
	_n="${1%%|*}"; _t="${1#*|}"
	_p="$STLDIR/$_n"
	_want="$(norm_target "$_p" "$_t")"
	if [ "$(symlink_actual "$_p")" = "$_want" ] && [ -e "$_p" ]; then
		ok "$_n 已就绪，跳过"; return 3
	fi
	_tmp="$_p.kpnew.$$"
	rm -rf "$_tmp" 2>/dev/null
	ln -sfn "$_t" "$_tmp" 2>/dev/null || { rm -rf "$_tmp"; no "$_n 创建软链失败"; return 1; }
	mv -f "$_tmp" "$_p" 2>/dev/null || { rm -rf "$_tmp"; no "$_n 落位失败"; return 1; }
	ok "$_n -> $_t"
	return 0
}

fix_uci_set() {  # <key>=<value>
	_k="${1%%=*}"; _v="${1#*=}"
	case "$_k" in
		uhttpd.openwrt8080.*) ;;
		*) no "拒绝修改非 8080 段的 key: $_k"; return 1 ;;
	esac
	if [ "$(uci -q get "$_k" 2>/dev/null)" = "$_v" ]; then ok "$_k 已就绪，跳过"; return 3; fi
	uci -q set "$_k=$_v" || { no "uci set $_k 失败"; return 1; }
	uci -q commit uhttpd || { no "uci commit 失败"; return 1; }
	ok "$_k = $_v"
	/etc/init.d/uhttpd reload >/dev/null 2>&1 || true
	return 0
}

fix_by_action() {  # <fix> <fixarg>  → 0=已修 1=失败 2=无动作 3=已就绪
	case "$1" in
		none) return 2 ;;
		symlink) fix_symlink "$2" ;;
		clear_cache) clear_luci_cache; ok "已清 LuCI 缓存（两份）"; return 0 ;;
		uci_set) fix_uci_set "$2" ;;
		deploy)
			case "$2" in
				disp)   deploy_dispatcher ;;
				view:*) deploy_view "${2#view:}" ;;
				ctrl:*) deploy_controller "${2#ctrl:}" ;;
				portal) install_portal ;;
				*) no "未知 deploy 目标: $2"; return 1 ;;
			esac ;;
		*) return 2 ;;
	esac
}

gate_ok() {  # <gate>
	case "$1" in
		auto) return 0 ;;
		deploy) [ "${KP_DEPLOY:-0}" = 1 ] && [ "$MODE_DEPLOY" = 1 ] && return 0; return 1 ;;
		shared) [ "${KP_DEPLOY_SHARED:-0}" = 1 ] && [ "$MODE_CTRL" = 1 ] && return 0; return 1 ;;
		*) return 1 ;;
	esac
}

gate_hint() {
	case "$1" in
		deploy) printf '需 KP_DEPLOY=1 且加 --deploy' ;;
		shared) printf '需 KP_DEPLOY_SHARED=1 且加 --controllers' ;;
		manual) printf '仅人工处理（脚本不自动改）' ;;
		*) printf '-' ;;
	esac
}

# ---------------------------------------------------------------------------
# 10. manifest 引擎
# ---------------------------------------------------------------------------
NORM="$TMP/manifest.norm"

normalize_manifest() {
	[ -f "$MANIFEST" ] || die "找不到判据表: $MANIFEST"
	awk -F'\t' '
		/^[[:space:]]*#/ { next }
		NF < 12 { next }
		{
			for (i = 1; i <= 12; i++) if ($i == "") $i = "-"
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
				$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
		}
	' "$MANIFEST" > "$NORM" 2>/dev/null
	[ -s "$NORM" ] || die "判据表解析为空（$MANIFEST）"
	return 0
}

record()         { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESFILE"; }
record_replace() {  # <id> <result> <actual>  —— 覆盖同一 id 的旧记录
	grep -v "^$1${TAB}" "$RESFILE" > "$RESFILE.tmp" 2>/dev/null
	mv -f "$RESFILE.tmp" "$RESFILE" 2>/dev/null
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESFILE"
}

row_line() {  # <id> <result> <feature> <actual> <desc>
	_tag='OK'; _col="$C_G"
	case "$2" in
		FAIL)  _tag='NG'; _col="$C_R" ;;
		WARN)  _tag='!'; _col="$C_Y" ;;
		INFO)  _tag='i'; _col="$C_B" ;;
		SKIP)  _tag='-'; _col="$C_D" ;;
		BLOCK) _tag='?'; _col="$C_Y" ;;
	esac
	_nm="$3"; [ "$_nm" = '-' ] && _nm="$5"
	printf "${_col}[%s]${C_N} %-5s %s  ${C_D}|${C_N} %s\n" "$_tag" "$1" "$_nm" "$4"
}

count_result() {
	case "$1" in
		PASS) CNT_PASS=$((CNT_PASS + 1)) ;;
		FAIL) CNT_FAIL=$((CNT_FAIL + 1)) ;;
		WARN) CNT_WARN=$((CNT_WARN + 1)) ;;
		INFO) CNT_INFO=$((CNT_INFO + 1)) ;;
		SKIP) CNT_SKIP=$((CNT_SKIP + 1)) ;;
		BLOCK) CNT_BLOCKED=$((CNT_BLOCKED + 1)) ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# 11. 报告
# ---------------------------------------------------------------------------
report_head() {
	sec "环境"
	_rel="$( ( . /etc/openwrt_release 2>/dev/null; printf '%s' "${DISTRIB_DESCRIPTION:-未知}" ) )"
	printf '  主机名      : %s\n' "$(cat /proc/sys/kernel/hostname 2>/dev/null)"
	printf '  机型        : %s\n' "$(cat /tmp/sysinfo/model 2>/dev/null || echo '(未知)')"
	printf '  固件        : %s\n' "$_rel"
	printf '  脚本版本    : v%s\n' "$VERSION"
	printf '  判据表      : %s（%s 行）\n' "$MANIFEST" "$(wc -l < "$NORM" | tr -d ' ')"
	printf '  8080 监听   : %s\n' "$(uci -q get uhttpd.openwrt8080.listen_http 2>/dev/null)"
	printf '  探测基准    : %s\n' "$CGIBASE"
	printf '  overlay 余量: %s\n' "$(df -h "$KP_ROOT" 2>/dev/null | tail -1 | awk '{print $4" / "$2}')"
	printf '  备份根      : %s\n' "$KP_BAK_ROOT"
}

report_summary() {
	sec "汇总"
	printf '  PASS=%s  FAIL=%s  WARN=%s  INFO=%s  SKIP=%s  FIXED=%s' \
		"$CNT_PASS" "$CNT_FAIL" "$CNT_WARN" "$CNT_INFO" "$CNT_SKIP" "$CNT_FIXED"
	[ "$CNT_BLOCKED" -gt 0 ] && printf '  BLOCKED=%s' "$CNT_BLOCKED"
	echo
	if [ "$CNT_FAIL" -gt 0 ]; then
		echo
		warn "未通过项（FAIL）："
		awk -F'\t' '{ if ($2 == "FAIL") printf "  %s  %s\n", $1, $3 }' "$RESFILE"
	fi
	return 0
}

report_features() {
	sec "8080 实例功能清单"
	_cur=''
	while IFS="$TAB" read -r id group feature kind subject pattern expect level gate fix fixarg desc; do
		[ "$feature" = '-' ] && continue
		if [ "$group" != "$_cur" ]; then
			_cur="$group"
			printf "\n${C_B}-- %s${C_N}\n" "$group"
		fi
		_res='PASS'; _act=''
		_l="$(grep "^$id${TAB}" "$RESFILE" 2>/dev/null | head -1)"
		if [ -n "$_l" ]; then
			_res="$(printf '%s' "$_l" | cut -f2)"
			_act="$(printf '%s' "$_l" | cut -f3)"
		fi
		_tag='OK'; _col="$C_G"
		case "$_res" in
			FAIL)  _tag='NG'; _col="$C_R" ;;
			WARN)  _tag='!'; _col="$C_Y" ;;
			INFO)  _tag='i'; _col="$C_B" ;;
			SKIP)  _tag='-'; _col="$C_D" ;;
			BLOCK) _tag='?'; _col="$C_Y" ;;
		esac
		printf "  ${_col}[%s]${C_N} %s  ${C_D}|${C_N} %s\n" "$_tag" "$feature" "$_act"
	done < "$NORM"
	return 0
}

# ---------------------------------------------------------------------------
# 12. 参数
# ---------------------------------------------------------------------------
parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--fix)         MODE_FIX=1 ;;
			--deploy)      MODE_DEPLOY=1 ;;
			--controllers) MODE_DEPLOY=1; MODE_CTRL=1 ;;
			--portal)      MODE_PORTAL=1 ;;
			--backup)      MODE_BACKUP=1 ;;
			--list)        MODE_LIST=1 ;;
			--quiet)       MODE_QUIET=1 ;;
			--only)        shift; ONLY_ID="${1:-}" ;;
			-h|--help)     usage; exit 0 ;;
			*) warn "未知参数: $1"; usage; exit 1 ;;
		esac
		shift
	done
	if [ "$MODE_DEPLOY" = 1 ] && [ "${KP_DEPLOY:-0}" != 1 ]; then
		warn "--deploy 已给出但 KP_DEPLOY != 1（deploy 级修复仍不会执行）"
	fi
	if [ "$MODE_CTRL" = 1 ] && [ "${KP_DEPLOY_SHARED:-0}" != 1 ]; then
		warn "--controllers 已给出但 KP_DEPLOY_SHARED != 1"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# 13. 主流程
# ---------------------------------------------------------------------------
main() {
	parse_args "$@"

	sec "kp-8080.sh v$VERSION"
	need_root

	has curl && HAVE_CURL=1
	if [ "${KP_ON_PC:-0}" = 1 ]; then
		NOPROXY='--noproxy *'
	else
		case "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" in
			*'//'*) NOPROXY='--noproxy *' ;;
		esac
	fi

	if [ "${ROLLBACK:-0}" = 1 ]; then do_rollback; exit 0; fi
	[ "$MODE_LIST" = 1 ] && { list_backups; exit 0; }
	[ "$MODE_BACKUP" = 1 ] && { do_backup; exit 0; }

	is_device || die "未检测到鲲鹏 8080 实例（$KP_ROOT 缺失，或 uci 无 uhttpd.openwrt8080）"

	LANIP="$(lan_ip)"
	[ -n "$LANIP" ] || die "无法确定 8080 监听地址（可用 KP_LAN_IP 覆盖）"
	CGIBASE="http://$LANIP:8080/cgi-bin/luci"
	STABASE="http://$LANIP:8080"

	normalize_manifest

	# 门户装回（在探活之前做，这样后面的判据能直接看到结果）
	if [ "$MODE_PORTAL" = 1 ]; then
		sec "装回 80 口门户 v3"
		install_portal || warn "门户装回未完全成功（见上方输出）"
	fi

	report_head

	# ---- 登录（一次）----
	if [ "$HAVE_CURL" = 1 ]; then
		step "登录 8080（$KPUSER@$LANIP:8080，凭据不落盘）"
		if login; then ok "会话已建立"
		else warn "登录失败 —— 页面类判据记为 BLOCKED（不计入 FAIL）"; fi
	fi
	cached_get "$CGIBASE/admin/status/details"
	if [ "$K_CODE" = 200 ]; then HTTP_OK=1; else HTTP_OK=0; fi

	sec "判据遍历"
	if [ "$MODE_FIX" = 1 ]; then
		info "模式 --fix：auto 级自动修；deploy/shared 需显式授权"
	else
		info "模式 只读（默认）：不改动设备任何文件"
	fi

	while IFS="$TAB" read -r id group feature kind subject pattern expect level gate fix fixarg desc; do
		[ -n "$ONLY_ID" ] && [ "$id" != "$ONLY_ID" ] && continue

		case "$kind" in
			http_code|http_body)
				if [ "$HTTP_OK" = 0 ]; then
					row_line "$id" BLOCK "$feature" "环境不可达（登录/首页门禁未过）" "$desc"
					record "$id" BLOCK 'HTTP 门禁未过'
					CNT_BLOCKED=$((CNT_BLOCKED + 1))
					continue
				fi ;;
		esac

		dispatch_kind
		row_line "$id" "$RESULT" "$feature" "$ACTUAL" "$desc"
		count_result "$RESULT"
		record "$id" "$RESULT" "$ACTUAL"

		[ "$MODE_FIX" = 1 ] || continue
		[ "$RESULT" = PASS ] && continue
		case "$kind" in static_code|portal_card_count|portal_body) continue ;; esac
		if [ "$fix" = none ]; then
			# WARN/INFO 级不通过≠故障，别用 [NG] 吓人（仅 FAIL 才红字）
			if [ "$level" = FAIL ]; then
				no "$id 无可自动修复动作 → $(gate_hint "$gate")"
			else
				warn "$id（$level）无自动修复动作 → $(gate_hint "$gate")"
			fi
			continue
		fi
		if ! gate_ok "$gate"; then
			warn "$id 修复被授权闸门拦下（gate=$gate）→ $(gate_hint "$gate")"
			continue
		fi
		step "$id 修复中（fix=$fix $fixarg）"
		fix_by_action "$fix" "$fixarg"
		_rc=$?
		case "$_rc" in
			0)
				rm -f "$HTTPDIR"/* 2>/dev/null
				[ "$HAVE_CURL" = 1 ] && login
				dispatch_kind
				if [ "$RESULT" = PASS ]; then
					ok "$id 复核通过（$ACTUAL）"
					CNT_FIXED=$((CNT_FIXED + 1))
					CNT_FAIL=$((CNT_FAIL - 1))
					record_replace "$id" PASS "$ACTUAL"
				else
					# WARN/INFO 级复核未达 PASS 属正常（不是故障），别用 [NG]
					if [ "$RESULT" = FAIL ]; then
						no "$id 复核仍未通过（$RESULT $ACTUAL）"
					else
						warn "$id 复核为 $RESULT（$ACTUAL）—— 非故障级，已记录"
					fi
					record_replace "$id" "$RESULT" "$ACTUAL"
				fi ;;
			3) skip_note "$id" ;;
			2) warn "$id 无可执行修复动作" ;;
			*) no "$id 修复失败" ;;
		esac
	done < "$NORM"

	report_summary
	report_features

	echo
	if [ "$MODE_FIX" = 1 ]; then
		if [ "$CNT_FIXED" = 0 ] && [ "$CNT_FAIL" = 0 ]; then
			ok "系统已就绪，本轮零修复（幂等终态）"
		else
			info "本轮修复 $CNT_FIXED 项，剩余 FAIL=$CNT_FAIL"
		fi
	fi
	if [ "$CNT_FAIL" = 0 ] && [ "$CNT_BLOCKED" = 0 ]; then
		ok "全部判据通过"
	elif [ "$CNT_FAIL" -gt 0 ]; then
		no "存在 $CNT_FAIL 项未通过 —— 见上方 [NG] 行"
	fi

	echo
	dim "  复验（只读）：sh $0"
	dim "  幂等修复    ：sh $0 --fix"
	dim "  列备份      ：sh $0 --list"
	dim "  回滚        ：ROLLBACK=1 sh $0"

	[ "$CNT_FAIL" -eq 0 ] && [ "$CNT_BLOCKED" -eq 0 ]
}

skip_note() { info "$1 已就绪，无需改动"; }

main "$@"
