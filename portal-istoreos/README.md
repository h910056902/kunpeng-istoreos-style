# portal-istoreos

> 鲲鹏 C2000 U（NRadio，OpenWrt 21.02.7）**80 端口门户内嵌 8080 界面 + 小字开关** 的一行安装补丁。

把设备上 `http://192.168.66.1/cgi-bin/portal`（`nr_webui` 门户）的「高级配置」弹层，
从原来错误的目标改到 **`http://192.168.66.1:8080/cgi-bin/luci/admin/quickstart/`**，
并在弹层里加一个**设备级生效**的「小字：已显示 / 已隐藏」开关。

---

## 一行命令安装

SSH 到设备（`root`），执行：

```sh
wget -qO /tmp/kp-portal.sh https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/install.sh && sh /tmp/kp-portal.sh
```

无 `wget` 时用 `curl`：

```sh
curl -fsSL https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/install.sh -o /tmp/kp-portal.sh && sh /tmp/kp-portal.sh
```

装完访问：

| 入口 | 地址 |
|---|---|
| 门户首页 | `http://192.168.66.1/cgi-bin/portal` |
| 内嵌页面 | `http://192.168.66.1:8080/cgi-bin/luci/admin/quickstart/` |

---

## 它改了什么

| # | 目标 | 改动 |
|---|---|---|
| 1 | `/www/cgi-bin/portal` | 弹层 iframe 目标改为 **8080 quickstart**；新增小字开关按钮 + 自处理 `?kp_toggle=1`；版本标记 `N R WEBUI_PORTAL=1.2` |
| 2 | `/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/quickstart/main.htm` | 在 `<%+footer%>` 前注入 marker 块：`?kp_small=1` 时输出 8 个类的 `display:none !important` |
| 3 | `/etc/config/kp_portal`（新建） | `config portal 'ui'` / `option hide_small '0'`（**0 = 显示，默认**） |

### 小字开关的工作链路

```
弹层按钮「小字：已显示」
      │  GET /cgi-bin/portal?kp_toggle=1
      ▼
portal（Lua）读到 kp_toggle=1
      │  翻转 uci kp_portal.ui.hide_small  0↔1
      │  uci commit
      ▼
302 → /cgi-bin/portal            （回到门户，按钮文案随之切换）
      │
      ▼
弹层 iframe = .../quickstart/            （hide_small=0，小字可见）
           或 .../quickstart/?kp_small=1 （hide_small=1，小字隐藏）
      │
      ▼
main.htm 里 <% if formvalue("kp_small")=="1" %> 输出 <style id="kp-nosmall">
```

**偏好存在 UCI，是设备级、跨浏览器、重启不丢的**；不是 localStorage。

---

## 为什么这么写（踩过的坑）

1. **`uci set` 不能创建新配置文件**
   `uci set kp_portal.ui.hide_small=0` 直接报 `Entry not found`（rc=1）。
   必须先 `touch /etc/config/kp_portal`，再 `uci set`。`kp-portal.sh` 里已带这步。

2. **固件没有 `base64` / `od` / `openssl` / `xxd`**
   二进制或精确文本传输只能走 `printf '\NNN'` 或 heredoc。
   本仓库的 `payload/` 是**用 `hexdump -C` 从设备回抽**并逐字节对账的
   （见 `scripts/_kp_extract_payload.py`），`portal.lua` md5
   `2883e12e4956d9b2bfaa0688c98b2d33`、`quickstart-main.htm` md5
   `86586d5345a348601d4a86e138ef0829`。

3. **`hexdump -C` 的 `*` 是重复行压缩标记**
   连续两行以上内容相同 → 只打一行 + 一个 `*`（POSIX 行为）。
   直接按行拼 hex 会**少字节**（14063 → 13871）。必须按**偏移量**还原。
   另外结尾有一个**裸偏移行**（如 `000036ef`）表示 EOF，不是垃圾。

4. **隐藏小字必须用 `!important` 且白名单**
   8080 的 SPA 规则带 `[data-v-xxxx]` 作用域，特化度更高，不加 `!important` 无效。
   且**绝不能碰 `.desc`** —— 那是首屏 24px 大字标题；
   `.actioner-tips` / `.body-tips` 是弹窗容器，隐藏会让整个向导消失。
   已确认隐藏的 8 个类：
   `.subtitle` `.cbi-value-description` `.cbi-map-descr`
   `.module-settings__sub` `.module-settings__desc`
   `.label-item_tips` `.custom-content .tip` `.speed_title`

5. **busybox ash 不支持 `trap ... ERR`**
   只有 `EXIT` / `INT` / `TERM` 可靠。

6. **`raw.githubusercontent.com` 有约 5 分钟 CDN 缓存**
   刚推送完立刻装可能拿到旧版；等 5 分钟或用带 `?t=<时间戳>` 的 raw 代理。

7. **git 仓库必须是 public，否则 raw 一律 404**
   `raw.githubusercontent.com` **对私有仓库的匿名请求返回 404**（不是 403），
   看起来像"文件不存在"，极易误判。本安装器托管在**公开仓库**
   `h910056902/kunpeng-istoreos-style`；若你 fork 到私有仓库，一行命令必然失败。
   判据：`gh api repos/<owner>/<repo> --jq .private` 应为 `false`。

8. **本改动不碰 80 端口官方 `main.htm`**
   `/usr/lib/lua/luci/view/quickstart/main.htm`（官方，2036 B，
   md5 `8ee8bd686f0da779b5b152000ab4ebb9`）保持原样，
   避免影响 80 端口的原厂界面。

---

## 回滚

```sh
ROLLBACK=1 sh /tmp/kp-portal.sh
```

会从 `/root/kp-bak-<时间戳>/` 里取**最近一次**备份恢复 `portal` 与 `main.htm`，
清 LuCI 缓存并重启 uhttpd。

也可手工：

```sh
cp /root/kp-bak-*/portal.bak   /www/cgi-bin/portal
cp /root/kp-bak-*/main.htm.bak /overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/quickstart/main.htm
rm -f /tmp/luci-indexcache; rm -rf /tmp/luci-modulecache/*
/etc/init.d/uhttpd restart
```

完全卸载（含 UCI 配置）：

```sh
rm -f /etc/config/kp_portal
uci -q delete kp_portal 2>/dev/null || true
```

---

## 仓库结构

```
portal-istoreos/
├── README.md                       # 本文件
├── install.sh                      # 一行命令入口（拉 kp-portal.sh + payload 并执行）
├── kp-portal.sh                    # 真正干活的补丁器（幂等 + 备份 + 回滚）
└── payload/
    ├── portal.lua                  # 已打补丁的 portal（md5 2883e12e…，14063 B）
    ├── quickstart-main.htm         # 注入后的 main.htm 参考副本（md5 86586d53…，3425 B）
    └── quickstart-nosmall.snippet  # 注入片段（marker 成对，供替换用）
```

`install.sh` 只做下载 + 转交；`kp-portal.sh` 是唯一有写操作的地方，
每次运行都会先备份，可用 `ROLLBACK=1` 撤销。

---

## 验证清单

装完逐条验：

```sh
# 1) portal 部署正确
md5sum /www/cgi-bin/portal
#   → 2883e12e4956d9b2bfaa0688c98b2d33

# 2) UCI 配置存在且默认显示
uci -q get kp_portal.ui.hide_small
#   → 0

# 3) 注入块存在且成对
grep -c 'KP-QUICKSTART-NOSMALLTEXT' \
  /overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/quickstart/main.htm
#   → 2

# 4) 80 端口官方文件未被改动
md5sum /usr/lib/lua/luci/view/quickstart/main.htm
#   → 8ee8bd686f0da779b5b152000ab4ebb9

# 5) 小字开关生效（切到隐藏）
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1/cgi-bin/portal?kp_toggle=1'
#   → 302
uci -q get kp_portal.ui.hide_small
#   → 1
```

浏览器侧：进门户 → 点「高级配置」→ 弹层里应是 **8080 quickstart**，
不是 istorerouter；右上角按钮可切换小字显隐，切完刷新仍是上次状态。
