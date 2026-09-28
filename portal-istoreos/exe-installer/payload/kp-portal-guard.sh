#!/bin/sh
# ============================================================================
#  kp-portal-guard.sh —— portal v3 自愈守卫
# ----------------------------------------------------------------------------
#  背景：nr_webui（WebUI V2.0.28）二进制里**内嵌了 portal 1.0 的完整源码**，
#        并在启动 / 自更新时会执行 `write /www/cgi-bin/portal`，
#        把我们的 v3 覆盖回原厂版（2026-09-28 11:00 实测发生过一次）。
#        实测：**普通 HTTP 请求不会触发**，只在 nr_webui 自更新/重启时发生。
#
#  策略：不去跟它抢写入权（抢不过，且会打乒乓），改为**分钟级自愈** ——
#        检测 /www/cgi-bin/portal 的 md5，不是 v3 就立刻从备份/云端打回。
#
#  幂等：可反复执行；金样本不存在时自动从备份或云端补拉。
#  cron：* * * * * /usr/bin/kp-portal-guard.sh >/dev/null 2>&1
#        ⚠️ crontab 里严禁写 $(...)（会被提前展开导致任务失效）
#        ⚠️ busybox cron 不认 % 转义 —— 命令里别带 %
# ============================================================================
set -eu

PORTAL='/www/cgi-bin/portal'
MAIN='/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/quickstart/main.htm'
GOLD='/root/kp-portal-gold'
GOLD_PORTAL="$GOLD/portal.v3"
GOLD_MAIN="$GOLD/main.htm"
WANT_MD5='9360ce8c9b0421ebb39c11306949861f'
WANT_VER='NRWEBUI_PORTAL=3.0'
LOG='/var/log/kp-portal-guard.log'
RAW="https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/payload"

log() {
	printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
	tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" || true
}

get() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 10 -o "$2" "$1" && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 15 -O "$2" "$1" && return 0
	fi
	return 1
}

ensure_gold() {
	mkdir -p "$GOLD"
	if [ ! -f "$GOLD_PORTAL" ]; then
		for b in $(ls -1t /root/kp-bak-*/portal.v3 /root/kp-bak-*/portal.bak 2>/dev/null); do
			if [ "$(md5sum "$b" 2>/dev/null | awk '{print $1}')" = "$WANT_MD5" ]; then
				cp -f "$b" "$GOLD_PORTAL"
				log "gold portal 从备份恢复: $b"
				break
			fi
		done
	fi
	if [ ! -f "$GOLD_PORTAL" ]; then
		if get "$RAW/portal.lua" "$GOLD_PORTAL" && \
		   [ "$(md5sum "$GOLD_PORTAL" 2>/dev/null | awk '{print $1}')" = "$WANT_MD5" ]; then
			log "gold portal 从云端拉取成功"
		else
			rm -f "$GOLD_PORTAL"
		fi
	fi
	if [ ! -f "$GOLD_MAIN" ]; then
		get "$RAW/quickstart-main.htm" "$GOLD_MAIN" || true
	fi
}

main() {
	ensure_gold

	# ---- 1) portal 自愈 ----
	if [ -f "$GOLD_PORTAL" ]; then
		cur="$(md5sum "$PORTAL" 2>/dev/null | awk '{print $1}')"
		if [ "$cur" != "$WANT_MD5" ]; then
			cp -f "$GOLD_PORTAL" "$PORTAL" && chmod 755 "$PORTAL"
			new="$(md5sum "$PORTAL" 2>/dev/null | awk '{print $1}')"
			if [ "$new" = "$WANT_MD5" ]; then
				log "portal 被覆盖(旧=$cur) → 已打回 v3"
			else
				log "portal 打回失败(得到 $new)"
			fi
		fi
	fi

	# ---- 2) 8080 quickstart main.htm 自愈（防 8080 环境被重建）----
	if [ -f "$MAIN" ] && [ -f "$GOLD_MAIN" ]; then
		if ! grep -q 'KP-QUICKSTART' "$MAIN" 2>/dev/null; then
			cp -f "$GOLD_MAIN" "$MAIN"
			log "main.htm 注入块丢失 → 已从金样本恢复"
		fi
	fi
}

main
exit 0
