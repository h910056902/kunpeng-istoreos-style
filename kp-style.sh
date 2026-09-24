#!/bin/sh
# ============================================================================
# kp-style.sh —— 鲲鹏 C2000 (NROS) 8080 LuCI 一键 iStoreOS 风格化
# 参考: guoguobuku/mt6000-istoreos（GL-iNet 不刷机风格化思路）
# 架构依据: docs/DESIGN.md（maye 安装器 install_openwrt_luci_8080 逆向）
#
# 约束: busybox ash 运行（无数组/无 tput/无 base64；find 无 -newer）
#       本脚本设计为"在路由器上直接运行"，凭据/SSH 由外部负责，本脚本不碰网络凭据
# 铁律: 每个写操作前先备份；改 Lua 走 /tmp 语法校验；改完清 LuCI 缓存；读回验证
# ============================================================================
set -u

KP_ROOT="/overlay/nradio-apps/openwrt-luci-8080"
KP_DOCROOT="$KP_ROOT/www"
KP_CGI="$KP_DOCROOT/cgi-bin/luci"
KP_VIEW="$KP_ROOT/usr/lib/lua/luci/view"
KP_THEME_STATIC="$KP_DOCROOT/luci-static/bootstrap"
KP_THEME_VIEW="$KP_VIEW/themes/bootstrap"
KP_INDEX_CACHE="/tmp/luci-indexcache-bootstrap"
KP_BACKUP_BASE="/mnt/storage/data/kp-style-backup"
KP_WORK="/tmp/kp-style-work"

# ---- 终端输出（中文占 2 列，禁右边框/右对齐；非 tty 自动去色）----
if [ -t 1 ]; then
    C_G="\033[32m"; C_R="\033[31m"; C_Y="\033[33m"; C_B="\033[36m"; C_N="\033[0m"
else
    C_G=""; C_R=""; C_Y=""; C_B=""; C_N=""
fi
ui_ok()  { printf "${C_G}[OK]${C_N} %s\n" "$1"; }
ui_no()  { printf "${C_R}[NG]${C_N} %s\n" "$1"; }
ui_do()  { printf "${C_B}[..]${C_N} %s\n" "$1"; }
ui_warn(){ printf "${C_Y}[!]${C_N} %s\n" "$1"; }
ui_sec() { printf "\n${C_B}== %s ==${C_N}\n" "$1"; }
die()    { ui_no "$1"; exit 1; }

# ---- curl 失败立刻换 wget（本机 curl 与 wget 网络栈不同，双栈必带）----
kp_fetch() { # $1=url $2=out
    curl -fsSL -m 90 -o "$2" "$1" 2>/dev/null && return 0
    wget -qO "$2" "$1" 2>/dev/null && return 0
    return 1
}

now_tag() { date '+%Y%m%d_%H%M%S'; }

clear_luci_cache() {
    rm -rf "$KP_INDEX_CACHE" 2>/dev/null
    rm -rf /tmp/luci-modulecache 2>/dev/null
    ui_ok "LuCI 缓存已清理（$KP_INDEX_CACHE / luci-modulecache）"
}

# 8080 实例只绑在 LAN IP 上（不是 127.0.0.1），探 127.0.0.1 会得到 000 假阴性
kp_lan_ip() {
    ip=$(uci -q get uhttpd.openwrt8080.listen_http 2>/dev/null | awk -F: '{print $1}')
    case "$ip" in
        ""|\$*|0.0.0.0|\[::\]) ip=$(uci -q get network.lan.ipaddr 2>/dev/null) ;;
    esac
    case "$ip" in
        ""|\$*|0.0.0.0|\[::\]) ip=$(ip -4 addr show br-lan 2>/dev/null | grep -m1 -oE 'inet [0-9.]+' | awk '{print $2}') ;;
    esac
    printf '%s' "$ip"
}

# 页面健康检查：403=登录页正常（模板没崩），200/302 也算活，500=模板/脚本崩了，000=探不到
probe_8080() {
    ip=$(kp_lan_ip)
    [ -n "$ip" ] || { printf '000'; return; }
    url="http://$ip:8080/cgi-bin/luci/admin/status/details"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$url" 2>/dev/null)
    [ -n "$code" ] || code=$(wget -qS -O /dev/null "$url" 2>&1 | awk '/HTTP\//{print $2; exit}')
    [ -n "$code" ] || code=000
    printf '%s' "$code"
}

# ============================================================================
# 1) 体检与基线（只读）
# ============================================================================
do_selftest() {
    ui_sec "体检与基线（只读）"
    ui_do "检查 8080 实例文件"
    for f in "$KP_CGI" "$KP_THEME_STATIC" "$KP_THEME_VIEW" "$KP_VIEW/admin_status/nradio_details.htm" "$KP_VIEW/admin_status/nradio_8080_sysauth.htm"; do
        if [ -e "$f" ]; then ui_ok "存在: $f"; else ui_no "缺失: $f"; fi
    done
    ui_do "uhttpd.openwrt8080 配置"
    uci -q get uhttpd.openwrt8080.listen_http || ui_warn "uci 无 uhttpd.openwrt8080"
    ui_do "磁盘与内存"
    df -h "$KP_ROOT" 2>/dev/null | tail -n +1
    free -k | head -2
    ui_do "8080 页面探活（预期 403=登录页正常 / 200=已登录）"
    code=$(probe_8080)
    case "$code" in
        500) ui_no "HTTP 500 —— 设备总览模板可能已损坏，先回滚再操作" ;;
        000) ui_warn "HTTP 000 —— 无法确定 8080 监听地址或服务未启动（检查 uhttpd.openwrt8080）" ;;
        *)   ui_ok "HTTP $code" ;;
    esac
    ui_do "已有备份清单"
    ls -1 "$KP_BACKUP_BASE" 2>/dev/null || ui_warn "尚无备份目录"
}

# ============================================================================
# 2) 备份
# ============================================================================
do_backup() {
    ui_sec "备份 8080 实例"
    tag=$(now_tag)
    dest="$KP_BACKUP_BASE/$tag"
    mkdir -p "$dest" || die "无法创建备份目录 $dest"
    tar -czf "$dest/8080-root.tar.gz" -C "$KP_ROOT" . 2>/dev/null
    cp "$KP_CGI" "$dest/cgi-bin.luci.bak" 2>/dev/null
    uci show uhttpd > "$dest/uhttpd.uci.bak" 2>/dev/null
    [ -f /etc/config/argon ] && cp /etc/config/argon "$dest/argon.uci.bak"
    ls -l "$dest"
    # 校验：tar 必须能完整列出
    if tar -tzf "$dest/8080-root.tar.gz" > /dev/null 2>&1; then
        ui_ok "备份完成: $dest（tar 完整性校验通过）"
    else
        die "备份 tar 损坏，停止后续操作"
    fi
}

latest_backup() {
    ls -1 "$KP_BACKUP_BASE" 2>/dev/null | sort | tail -n 1
}

# ============================================================================
# 3) Argon 配置层升级（主色 / 暗色 / 模糊度 / 登录背景）
#
# ⚠ 本步骤刻意【不替换主题模板】。设备实测结论：
#   - 本实例的 LuCI 资源目录中没有 luci.js（全盘 find 无命中）；
#   - Argon 2.2.9.4 的 footer 依赖 `L.require('menu-argon')`，L 由 luci.js 提供；
#   - 强行把 1.8.4 主题换成 2.2.9.4 → 侧栏导航因 L 未定义而整体失效
#     （页面仍返回 200，探活查不出来，比现状更糟）。
#   因此采用「配置层升级」：主题模板不动，只升级 /etc/config/argon。
#   详见 docs/DESIGN.md 第五节。
# ============================================================================
ARGON_IPK_URLS="
https://mt3000.netlify.app/theme/luci-theme-argon-master_2.2.9.4_all.ipk
https://raw.githubusercontent.com/guoguobuku/mt6000-istoreos/master/theme/luci-theme-argon-master_2.2.9.4_all.ipk
"

do_argon_upgrade() {
    ui_sec "Argon 配置升级（配置层）"
    [ -d "$KP_THEME_STATIC" ] || die "未找到私有主题目录 $KP_THEME_STATIC"

    # 预烘焙 Argon 配置（不装 luci-app-argon-config，避免污染 80 端口菜单）
    # ⚠ 段类型必须是 `global`（= config global 'global'）。
    #   Argon 主题模板读的是 uci:get_first('argon', 'global', 'primary')，第二参数是【段类型】；
    #   若写成 `config argon 'global'`（段类型=argon），取值为 nil →
    #   渲染出 `--primary: ;` 空值，全站配色失效（本仓库踩过并已修复的坑）。
    cat > /tmp/argon_uci <<'EOF_ARGON'
config global 'global'
	option primary '#5e72e4'
	option dark_primary '#483d8b'
	option mode 'dark'
	option blur '4'
	option blur_dark '6'
	option transparency '0.5'
	option transparency_dark '0.45'
EOF_ARGON
    if [ -f /etc/config/argon ]; then
        cp /etc/config/argon "/etc/config/argon.kpbak-$(now_tag)"
        ui_warn "/etc/config/argon 已存在，已备份后覆盖"
    fi
    mv /tmp/argon_uci /etc/config/argon
    # 读回断言：段类型必须是 global，且 primary 非空
    if [ "$(uci -q get argon.global.primary)" = "#5e72e4" ]; then
        ui_ok "argon 配置就位（段类型 global，暗色 + 主色 #5e72e4 + 模糊 4）"
    else
        die "argon 配置读回断言失败（段类型应为 global），已中止"
    fi

    clear_luci_cache
    code=$(probe_8080)
    [ "$code" = "500" ] && ui_no "HTTP 500 —— 主题模板可能已损坏，执行回滚: 选项 6" || ui_ok "配置升级后探活 HTTP $code（403/200 均为正常）"
    ui_warn "浏览器请 Ctrl+F5 强刷以绕过旧 CSS 缓存"
}

# ============================================================================
# 4) 设备总览美化（部署 payload/admin_status/nradio_details.htm）
# ============================================================================
do_overview() {
    ui_sec "设备总览卡片化部署"
    pdir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/payload"
    [ -f "$pdir/admin_status/nradio_details.htm" ] || die "缺少 $pdir/admin_status/nradio_details.htm（侦察后生成，见 docs/DESIGN.md）"
    ts=$(now_tag)
    cp "$KP_VIEW/admin_status/nradio_details.htm" "$KP_VIEW/admin_status/nradio_details.htm.bak-$ts" || die "原页面备份失败"
    # htm 是 LuCI 模板（<% %>），用 lua loadfile 校不了模板；用渲染探活兜底：
    # 先落 /tmp 再 mv，失败即回滚
    cp "$pdir/admin_status/nradio_details.htm" /tmp/nradio_details_new.htm
    mv /tmp/nradio_details_new.htm "$KP_VIEW/admin_status/nradio_details.htm" || die "落盘失败"
    clear_luci_cache
    code=$(probe_8080)
    if [ "$code" = "500" ]; then
        mv "$KP_VIEW/admin_status/nradio_details.htm.bak-$ts" "$KP_VIEW/admin_status/nradio_details.htm"
        clear_luci_cache
        die "部署后 HTTP 500，已自动回滚到备份 nradio_details.htm.bak-$ts"
    fi
    ui_ok "设备总览已部署，探活 HTTP $code；浏览器 Ctrl+F5 查看效果"
}

# ============================================================================
# 5) 注册入口：鲲鹏商店 / 1Panel / Docker（向 CGI 包装器注入「服务」菜单）
# ============================================================================
do_register() {
    ui_sec "注册入口（鲲鹏商店 / 1Panel / Docker）"
    pdir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/payload"
    [ -f "$KP_CGI" ] || die "找不到 CGI 包装器 $KP_CGI"
    [ -f "$pdir/kp_services.lua" ] || die "缺少 $pdir/kp_services.lua"

    if grep -q 'KP-SERVICES-MARKER' "$KP_CGI"; then
        ui_warn "服务菜单补丁已存在（KP-SERVICES-MARKER），跳过重复注入"
    else
        # 锚点断言：设备文件与预期不符即拒绝注入
        if ! grep -q 'luci.dispatcher.indexcache = "/tmp/luci-indexcache-bootstrap"' "$KP_CGI"; then
            die "CGI 包装器锚点不存在，设备文件与预期不符，停止注入"
        fi
        ts=$(now_tag)
        cp "$KP_CGI" "$KP_CGI.bak-$ts" || die "CGI 备份失败"
        # 在锚点行之前插入补丁体
        awk -v body="$pdir/kp_services.lua" '
            !done && /^luci\.dispatcher\.indexcache = "\/tmp\/luci-indexcache-bootstrap"$/ {
                while ((getline line < body) > 0) print line
                done=1
            }
            { print }' "$KP_CGI" > /tmp/kp_cgi_new || die "补丁拼接失败"
        # 落盘前 lua 语法校验（不通过绝不替换）
        if lua -e "assert(loadfile('/tmp/kp_cgi_new'))" 2>/dev/null; then
            cp /tmp/kp_cgi_new "$KP_CGI" && chmod 755 "$KP_CGI" || {
                cp "$KP_CGI.bak-$ts" "$KP_CGI"; die "补丁落盘失败，已回滚"; }
            ui_ok "CGI 包装器已注入「服务」菜单（KP-SERVICES-MARKER）"
        else
            cp "$KP_CGI.bak-$ts" "$KP_CGI"
            die "拼接后 lua 语法校验未通过，已回滚，拒绝落盘"
        fi
    fi

    clear_luci_cache
    code=$(probe_8080)
    if [ "$code" = "500" ]; then
        ui_no "HTTP 500 —— 补丁异常，请回滚 CGI: ls $KP_CGI.bak-*"
    else
        ui_ok "注册后探活 HTTP $code（403=登录页/200=正常）"
        ui_ok "入口位于侧栏「服务」菜单：鲲鹏商店 / 1Panel 面板 / Docker 容器"
    fi
}

# ============================================================================
# 6) 回滚
# ============================================================================
do_rollback() {
    ui_sec "回滚"
    lb=$(latest_backup)
    [ -n "$lb" ] || die "没有任何备份可回滚"
    dest="$KP_BACKUP_BASE/$lb"
    ui_do "使用备份: $dest"
    tar -xzf "$dest/8080-root.tar.gz" -C "$KP_ROOT" || die "备份解包失败"
    [ -f "$dest/argon.uci.bak" ] && cp "$dest/argon.uci.bak" /etc/config/argon
    clear_luci_cache
    code=$(probe_8080)
    [ "$code" = "500" ] && ui_no "回滚后仍 HTTP 500，需要人工介入" || ui_ok "回滚完成，探活 HTTP $code"
}

# ============================================================================
# 7) 侦察导出（供 PC 侧分析真实页面/包装器，生成 payload）
# ============================================================================
do_recon() {
    ui_sec "侦察导出（只读）"
    out="/tmp/kp-recon-$(now_tag)"
    mkdir -p "$out"
    cp "$KP_CGI" "$out/cgi-bin_luci.lua" 2>/dev/null
    cp -r "$KP_VIEW/admin_status" "$out/admin_status" 2>/dev/null
    cp -r "$KP_THEME_STATIC" "$out/theme-bootstrap" 2>/dev/null
    cp -r "$KP_THEME_VIEW" "$out/theme-views" 2>/dev/null
    uci show uhttpd > "$out/uhttpd.uci" 2>/dev/null
    tar -czf "$out.tar.gz" -C "$(dirname "$out")" "$(basename "$out")" && rm -rf "$out"
    ui_ok "侦察包: $out.tar.gz（拷到 PC 解包分析）"
    ls -l "$out.tar.gz"
}

# ============================================================================
# 主菜单
# ============================================================================
while true; do
    printf "\n%s\n" "====== kp-style · 鲲鹏 8080 LuCI iStoreOS 风格化 ======"
    printf " 1) 体检与基线（只读）\n"
    printf " 2) 备份 8080 实例\n"
    printf " 3) Argon 配置升级（主色/暗色/模糊）\n"
    printf " 4) 设备总览卡片化部署（需 payload）\n"
    printf " 5) 注册入口: 鲲鹏商店 / 1Panel / Docker（需 payload）\n"
    printf " 6) 回滚最近备份\n"
    printf " 7) 侦察导出（只读，供 PC 侧生成 payload）\n"
    printf " q) 退出\n"
    printf "选择: "
    read -r ans
    case "$ans" in
        1) do_selftest ;;
        2) do_backup ;;
        3) do_argon_upgrade ;;
        4) do_overview ;;
        5) do_register ;;
        6) do_rollback ;;
        7) do_recon ;;
        q|Q) exit 0 ;;
        *) ui_warn "无效选择" ;;
    esac
done
