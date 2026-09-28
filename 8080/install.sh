#!/bin/sh
# ============================================================================
#  install.sh —— 鲲鹏 C2000 U · 8080 LuCI 实例「一键校验」引导器
# ----------------------------------------------------------------------------
#  这一层的唯一职责：把 kp-8080.sh + manifest.tsv 抓到设备 /tmp 并交给它。
#  真正的判定 / 修复 / 部署逻辑全在 kp-8080.sh，本文件刻意保持「薄」。
#
#  设备上一行命令（推荐）：
#    cd /tmp && { curl -fsSL --connect-timeout 10 -o kp8080.sh \
#        "https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/${KP_REF:-main}/8080/install.sh" \
#      || wget -q -T 15 -O kp8080.sh \
#        "https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/${KP_REF:-main}/8080/install.sh"; } \
#      && sh kp8080.sh
#
#  默认 = 只读全量校验（不改设备任何文件）；加 --fix 才做低风险幂等修复。
#
#  环境变量：
#    KP_REF     分支/标签（默认 main）
#    KP_REPO    owner/repo 覆盖（默认 h910056902/kunpeng-istoreos-style）
#    KP_WORK    落地目录（默认 /tmp/kp8080-boot）
#    KP_ON_PC   在 PC 上跑时置 1（curl 一律 --noproxy '*'，避开本机代理劫持）
#    KP_KEEP    置 1 则退出时保留 KP_WORK
#
#  设计铁律（踩过的坑，别改）：
#   · busybox ash：**无数组**，`trap` 只认 EXIT/HUP/INT/TERM
#   · 用 `set -u`，**绝不用 `set -e`**（wget/curl 里 `||` 链会被误杀）
#   · kp-8080.sh 末尾自带 `main "$@"`，所以只能 **exec/`sh` 调用**，严禁 `. source`
#   · 下载必须带**体积下界**校验：被门户/劫持页顶替时体积会异常，早失败早报错
#   · 一切路径用绝对路径；设备 /tmp 与 PC 的 Git-Bash 都可用
# ============================================================================
set -u

VERSION='1.0.0'

KP_REPO="${KP_REPO:-h910056902/kunpeng-istoreos-style}"
KP_REF="${KP_REF:-main}"
KP_SUB="${KP_SUB:-8080}"
KP_WORK="${KP_WORK:-/tmp/kp8080-boot}"
KP_KEEP="${KP_KEEP:-0}"

BASE="https://raw.githubusercontent.com/$KP_REPO/$KP_REF/$KP_SUB"
ALT="https://cdn.jsdelivr.net/gh/$KP_REPO@$KP_REF/$KP_SUB"

MIN_MAIN=20000     # kp-8080.sh 实测 36,662 B
MIN_MANIFEST=8000  # manifest.tsv 实测 16,777 B

# --- 颜色 / 输出（与 kp-8080.sh 保持同一套 ASCII 标记）-----------------------
if [ -t 1 ]; then
	C_G="$(printf '\033[32m')"; C_R="$(printf '\033[31m')"
	C_Y="$(printf '\033[33m')"; C_B="$(printf '\033[36m')"
	C_D="$(printf '\033[2m')"; C_N="$(printf '\033[0m')"
else
	C_G=''; C_R=''; C_Y=''; C_B=''; C_D=''; C_N=''
fi
ok()   { printf "${C_G}[OK]${C_N} %s\n" "$*"; }
no()   { printf "${C_R}[NG]${C_N} %s\n" "$*" >&2; }
warn() { printf "${C_Y}[!]${C_N} %s\n" "$*"; }
info() { printf "${C_B}[i]${C_N} %s\n" "$*"; }
dim()  { printf "${C_D}%s${C_N}\n" "$*"; }

# --- 代理规避 ----------------------------------------------------------------
NOPROXY=''
if [ "${KP_ON_PC:-0}" = 1 ]; then
	NOPROXY='--noproxy *'
else
	case "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" in
		*'//'*) NOPROXY='--noproxy *' ;;
	esac
fi

HAVE_CURL=0
command -v curl >/dev/null 2>&1 && HAVE_CURL=1
HAVE_WGET=0
command -v wget >/dev/null 2>&1 && HAVE_WGET=1

size_of() { wc -c < "$1" 2>/dev/null | tr -d ' '; }
md5of()   { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

cleanup() {
	[ "${KP_KEEP:-0}" = 1 ] && return 0
	case "${KP_WORK:-}" in
		/dev/null|''|/|/tmp) return 0 ;;
	esac
	[ -d "${KP_WORK:-/nonexistent}" ] && rm -rf "$KP_WORK" 2>/dev/null
	return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
	cat <<EOF
install.sh v$VERSION —— 8080 实例一键校验引导器

用法：sh install.sh [kp-8080.sh 的选项...]

  本脚本只负责下载 kp-8080.sh + manifest.tsv，随后把参数原样交给它。
  选项含义见：sh install.sh --help 之后的输出，或直接看 kp-8080.sh。

  常用：
    sh install.sh                      # 只读全量校验 + 打印功能清单
    sh install.sh --fix                # 低风险幂等修复
    KP_DEPLOY=1 sh install.sh --fix --deploy
    KP_DEPLOY=1 sh install.sh --portal # 装回 80 口门户 v3（四卡片）

环境变量：KP_REF KP_REPO KP_SUB KP_WORK KP_ON_PC KP_KEEP
          KP_DEPLOY KP_DEPLOY_SHARED KPUSER KPASS KP_LAN_IP
EOF
}

# --- 取文件（curl → wget → jsdelivr 镜像，三跳）-------------------------------
grab() {  # <relpath> <dst> <minbytes>
	_rel="$1"; _dst="$2"; _min="$3"
	_urls="$BASE/$_rel $ALT/$_rel"
	for _u in $_urls; do
		if [ "$HAVE_CURL" = 1 ]; then
			curl -fsSL --connect-timeout 10 -m 60 $NOPROXY -o "$_dst" "$_u" 2>/dev/null
		elif [ "$HAVE_WGET" = 1 ]; then
			wget -q -T 20 -O "$_dst" "$_u" 2>/dev/null
		else
			return 2
		fi
		_s="$(size_of "$_dst")"; [ -z "$_s" ] && _s=0
		if [ "$_s" -ge "$_min" ]; then
			dim "    ← $_u（$_s B）"
			return 0
		fi
		rm -f "$_dst" 2>/dev/null
	done
	return 1
}

# --- 主流程 ------------------------------------------------------------------
printf "${C_B}== install.sh v$VERSION ==${C_N}\n"
printf '  仓库      : %s@%s\n' "$KP_REPO" "$KP_REF"
printf '  目录      : %s\n' "$KP_SUB"
printf '  工作区    : %s\n' "$KP_WORK"
printf '  下载器    : %s\n' "$( [ "$HAVE_CURL" = 1 ] && echo curl || { [ "$HAVE_WGET" = 1 ] && echo wget || echo '（无）'; } )"

if [ "$HAVE_CURL" = 0 ] && [ "$HAVE_WGET" = 0 ]; then
	no "设备上既无 curl 也无 wget —— 无法下载（请先 opkg install curl）"
	exit 1
fi

# 本地就地运行：仓库内直接 `sh 8080/install.sh`
_self="$(dirname "$0" 2>/dev/null || echo .)"
if [ -f "$_self/kp-8080.sh" ] && [ -f "$_self/manifest.tsv" ]; then
	info "检测到本地副本，跳过下载：$_self/kp-8080.sh"
	KP_DIR="$(cd "$_self" && pwd)"
	export KP_DIR
	exec sh "$KP_DIR/kp-8080.sh" "$@"
fi

mkdir -p "$KP_WORK" 2>/dev/null || { no "无法创建 $KP_WORK"; exit 1; }

printf "\n${C_B}-- 拉取脚本与判据表${C_N}\n"
grab 'kp-8080.sh'  "$KP_WORK/kp-8080.sh"  "$MIN_MAIN"     || { no "kp-8080.sh 下载失败（体积不足 ${MIN_MAIN}B，可能是被劫持页顶替）"; exit 1; }
grab 'manifest.tsv' "$KP_WORK/manifest.tsv" "$MIN_MANIFEST" || { no "manifest.tsv 下载失败（体积不足 ${MIN_MANIFEST}B）"; exit 1; }

# 语法自检：宁可在这里死，也别在里面半死
sh -n "$KP_WORK/kp-8080.sh" 2>/dev/null || { no "kp-8080.sh 语法自检未通过（下载残缺？）"; exit 1; }
ok "引导就绪：kp-8080.sh $(size_of "$KP_WORK/kp-8080.sh") B / manifest.tsv $(size_of "$KP_WORK/manifest.tsv") B"
dim "  kp-8080.sh md5 = $(md5of "$KP_WORK/kp-8080.sh")"

# payload 由 kp-8080.sh 按需（仅在 --fix/--deploy 真要落盘时）从这个基址取
KP_DIR="$KP_WORK"
KP_RAW_BASE="$BASE"
export KP_DIR KP_RAW_BASE
export KP_REF

exec sh "$KP_WORK/kp-8080.sh" "$@"
