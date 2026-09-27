#!/usr/bin/lua
-- NRWEBUI_PORTAL=1.2  (kp: "istore os风格化" 弹层改为内嵌 8080 quickstart；新增小字开关)
--
-- 变更历史（本行以下为鲲鹏 8080 定制增量，非 nr_webui 原厂内容）：
--   1.0  原厂：两个入口（美化版 / 官方界面）
--   1.1  增加第三张卡「istore os风格化」，弹层内嵌 80 端口的 admin/istorerouter
--   1.2  修 1.1 弹错页 -> 弹层改为内嵌 :8080/cgi-bin/luci/admin/quickstart/
--        并新增「小字：显示/隐藏」开关（设备级，偏好存 UCI /etc/config/kp_portal）
--
-- 开关落地机制（重要，别改成别的写法）：
--   * 本 CGI 自己处理 `?kp_toggle=1`：翻转 UCI 后 302 回本页（不要另起一个 CGI 文件）
--   * UCI 语义：hide_small=1 表示「隐藏小字」，默认 0（= 显示，保持原观感）
--   * iframe URL 只在 hide_small=1 时拼 `?kp_small=1`；默认不带参数
--   * 8080 侧 main.htm 只在收到 kp_small=1 时才输出隐藏 <style>（零副作用）
local CONF_PATHS = {"/root/webui.conf"}
local KPCFG = "kp_portal"          -- uci 配置名

-- ---------------------------------------------------------------------------
-- 小字开关的 UCI 读写
--   ⚠️ 实测：`uci set kp_portal.ui=portal` 在配置文件**不存在**时会报
--      "Entry not found" 且 rc=1 —— 必须先 `touch /etc/config/kp_portal`。
--      这是 busybox uci 的行为，不是我们写错。
-- ---------------------------------------------------------------------------
local function uci_get_hide_small()
    local pf = io.popen("uci -q get " .. KPCFG .. ".ui.hide_small 2>/dev/null")
    if not pf then return "0" end
    local v = pf:read("*a") or ""
    pf:close()
    v = v:gsub("%s+", "")
    if v ~= "0" and v ~= "1" then return "0" end
    return v
end

local function uci_set_hide_small(val)
    if val ~= "0" and val ~= "1" then return false end
    -- touch 必须在前；set/commit 之后回读确认
    os.execute("touch /etc/config/" .. KPCFG .. " 2>/dev/null")
    os.execute("uci set " .. KPCFG .. ".ui=portal 2>/dev/null")
    os.execute("uci set " .. KPCFG .. ".ui.hide_small=" .. val .. " 2>/dev/null")
    os.execute("uci commit " .. KPCFG .. " 2>/dev/null")
    return uci_get_hide_small() == val
end

local function read_conf()
    local c = { port = "10086", entry_select = "0", default_beauty = "0" }
    for _, p in ipairs(CONF_PATHS) do
        local f = io.open(p, "r")
        if f then
            for line in f:lines() do
                local k, v = line:match("^%s*([%w_]+)%s*=%s*(%S+)%s*$")
                if v and v ~= "" then
                    if k == "WEBUI_PORT" then c.port = v
                    elseif k == "WEB_ENTRY_SELECT" then c.entry_select = v
                    elseif k == "WEB_ENTRY_DEFAULT_BEAUTY" then c.default_beauty = v
                    end
                end
            end
            f:close()
        end
    end
    return c
end

local function webui_alive()
    local pf = io.popen("pidof nr_webui 2>/dev/null")
    if pf then
        local s = pf:read("*a")
        pf:close()
        if s and s:match("%d+") then
            return true
        end
    end
    return false
end

local function redirect(url)
    io.write("Status: 302 Found\r\n")
    io.write("Location: " .. url .. "\r\n")
    io.write("Cache-Control: no-store\r\n")
    io.write("Content-Type: text/html\r\n\r\n")
    io.write('<html><head><meta http-equiv="refresh" content="0; URL=' .. url .. '"></head><body>Redirecting...</body></html>')
end

-- ---------------------------------------------------------------------------
-- 小字开关：自处理分支（放在所有业务判断之前，保证任何时候都能切换）
--   GET /cgi-bin/portal?kp_toggle=1  -> 翻转 -> 302 回 /cgi-bin/portal
-- ---------------------------------------------------------------------------
local qs = os.getenv("QUERY_STRING") or ""
if qs:match("kp_toggle=1") then
    local cur = uci_get_hide_small()
    local nxt = (cur == "1") and "0" or "1"
    uci_set_hide_small(nxt)
    redirect("/cgi-bin/portal")
    return
end

local host = os.getenv("HTTP_HOST") or os.getenv("SERVER_NAME") or "192.168.66.1"
local hostname
if host:sub(1, 1) == "[" then
    hostname = host:match("^(%[[^%]]+%])") or host
else
    hostname = host:match("^([^:]+)") or host
    if hostname:find(":") then
        hostname = "[" .. hostname .. "]"
    end
end
local proto = "http"
local conf = read_conf()

local hide_small = uci_get_hide_small()
local beauty = string.format("%s://%s:%s/", proto, hostname, conf.port)
local official = string.format("%s://%s/cgi-bin/luci", proto, hostname)
local istoreos = string.format("%s://%s:8080/", proto, hostname)
-- ★ 1.2 修正：弹层目标从 80 端口的 istorerouter 改为 8080 端口的 quickstart
local quickstart_url = string.format("%s://%s:8080/cgi-bin/luci/admin/quickstart/", proto, hostname)
-- 带小字开关参数的 iframe 地址（仅 hide_small=1 时附加，默认不加）
local quickstart_frame = quickstart_url
if hide_small == "1" then
    quickstart_frame = quickstart_url .. "?kp_small=1"
end
local alive = webui_alive()

local auto = ""
local sub = "选择要进入的后台界面"

if not alive then
    redirect(official)
    return
end
if conf.entry_select == "0" then
    redirect(conf.default_beauty == "1" and beauty or official)
    return
end
if conf.default_beauty == "1" then
    auto = '<meta http-equiv="refresh" content="3; URL=' .. beauty .. '">'
    sub = "3 秒后自动进入美化版界面，也可手动选择"
end

-- 按钮文案：反映「点击后会发生什么」更直观，用当前状态决定
local small_btn_label
local small_btn_next
if hide_small == "1" then
    small_btn_label = "小字：已隐藏"
    small_btn_next = "点击显示小字"
else
    small_btn_label = "小字：已显示"
    small_btn_next = "点击隐藏小字"
end

local html = [[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">__AUTO__
<title>设备管理入口</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
    background: linear-gradient(135deg, #0f2c5c 0%, #1e4fa0 50%, #2a72d4 100%);
    display: flex; align-items: center; justify-content: center;
    color: #fff; padding: 20px;
  }
  .card {
    width: 100%; max-width: 460px;
    background: rgba(255,255,255,0.97);
    border-radius: 18px;
    box-shadow: 0 18px 50px rgba(0,0,0,0.35);
    padding: 40px 32px 28px;
    text-align: center;
    color: #1a2b4a;
  }
  .logo {
    width: 64px; height: 64px; margin: 0 auto 14px;
    border-radius: 16px;
    background: linear-gradient(135deg, #1e4fa0, #2a72d4);
    display: flex; align-items: center; justify-content: center;
  }
  .logo svg { width: 34px; height: 34px; fill: #fff; }
  h1 { font-size: 22px; font-weight: 700; letter-spacing: 1px; }
  .sub { margin-top: 8px; font-size: 13px; color: #6b7a99; }
  .opts { display: flex; flex-direction: column; gap: 14px; margin-top: 28px; }
  .opt {
    display: flex; align-items: center; gap: 14px;
    padding: 16px 18px; border-radius: 12px;
    text-decoration: none; color: #1a2b4a;
    border: 1.5px solid #e2e8f5; background: #f7f9fd;
    transition: transform .12s ease, box-shadow .12s ease, border-color .12s ease;
    cursor: pointer;
  }
  .opt:hover { transform: translateY(-2px); box-shadow: 0 8px 20px rgba(30,79,160,0.18); }
  .opt .ic {
    flex: 0 0 42px; width: 42px; height: 42px; border-radius: 10px;
    display: flex; align-items: center; justify-content: center;
  }
  .opt .ic svg { width: 22px; height: 22px; fill: #fff; }
  .opt.beauty .ic { background: linear-gradient(135deg, #2a72d4, #18b6c9); }
  .opt.official .ic { background: linear-gradient(135deg, #5a6b8c, #8493b3); }
  .opt.istoreos .ic { background: linear-gradient(135deg, #7b3ff2, #2a72d4); }
  .opt .txt { text-align: left; flex: 1; }
  .opt .t1 { font-size: 16px; font-weight: 600; }
  .opt .t2 { font-size: 12px; color: #8896b3; margin-top: 2px; }
  .opt .arrow { color: #c2ccdf; font-size: 20px; }
  .opt.beauty { border-color: #bfe0ff; background: linear-gradient(180deg,#f3f9ff,#eef5ff); }
  .opt.istoreos { border-color: #d5c2ff; background: linear-gradient(180deg,#f7f3ff,#f0eaff); }
  .tag {
    display: inline-block; font-size: 11px; color: #1e8fd0;
    background: #e3f4ff; border-radius: 6px; padding: 1px 7px; margin-left: 6px;
    vertical-align: middle;
  }
  .tag.new { color: #7b3ff2; background: #f0e9ff; }
  .foot { margin-top: 22px; font-size: 11px; color: #aab4c8; }
  .mask {
    display: none; position: fixed; inset: 0;
    background: rgba(8,18,40,0.72); z-index: 9999;
    align-items: center; justify-content: center; padding: 18px;
  }
  .mask.on { display: flex; }
  .modal {
    width: 100%; max-width: 900px; height: 82vh;
    background: #fff; border-radius: 14px; overflow: hidden;
    display: flex; flex-direction: column;
    box-shadow: 0 24px 70px rgba(0,0,0,0.5);
  }
  .mhead {
    display: flex; align-items: center; gap: 10px;
    padding: 12px 16px; border-bottom: 1px solid #e6ebf5;
    background: #f7f9fd; flex: 0 0 auto;
  }
  .mhead .mt { font-size: 15px; font-weight: 600; color: #1a2b4a; flex: 1; }
  .mhead button {
    border: none; font-size: 13px; padding: 7px 14px; border-radius: 8px; cursor: pointer;
  }
  .mhead .mb { background: #2a72d4; color: #fff; }
  .mhead .mb.ghost { background: #eaeff8; color: #47567a; }
  .mhead .mb.tog { background: #f0e9ff; color: #7b3ff2; }
  .mbody { flex: 1; position: relative; background: #fff; }
  .mbody iframe { width: 100%; height: 100%; border: 0; display: block; }
  .mtip {
    padding: 8px 16px; font-size: 12px; color: #7a87a3;
    background: #fbfcfe; border-top: 1px solid #eef2f8; flex: 0 0 auto;
  }
</style>
</head>
<body>
  <div class="card">
    <div class="logo">
      <svg viewBox="0 0 24 24"><path d="M12 2 3 7v10l9 5 9-5V7l-9-5zm0 2.3 6.5 3.6L12 11.5 5.5 7.9 12 4.3zM5 9.6l6 3.4v6.7l-6-3.3V9.6zm14 0v6.4l-6 3.3v-6.7l6-3.4z"/></svg>
    </div>
    <h1>设备管理入口</h1>
    <div class="sub">__SUB__</div>

    <div class="opts">
      <a class="opt istoreos" href="javascript:void(0)" onclick="openQuickstart(event)">
        <span class="ic">
          <svg viewBox="0 0 24 24"><path d="M4 6h16v2H4V6zm0 5h16v2H4v-2zm0 5h16v2H4v-2z"/><circle cx="7" cy="7" r="1.6"/><circle cx="7" cy="12" r="1.6"/><circle cx="7" cy="17" r="1.6"/></svg>
        </span>
        <span class="txt">
          <span class="t1">istore os风格化<span class="tag new">新</span></span>
          <span class="t2">在此直接配置；点「进入 8080 界面」打开完整页面</span>
        </span>
        <span class="arrow">›</span>
      </a>

      <a class="opt beauty" href="__BEAUTY__">
        <span class="ic">
          <svg viewBox="0 0 24 24"><path d="M12 3c-4.97 0-9 3.58-9 8 0 2.4 1.2 4.5 3.1 5.9L5 21l3.2-1.6c1 .3 2.1.5 3.3.5 4.97 0 9-3.58 9-8s-4.03-8-9-8zm-3.5 9.5a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm3.5 0a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3zm3.5 0a1.5 1.5 0 1 1 0-3 1.5 1.5 0 0 1 0 3z"/></svg>
        </span>
        <span class="txt">
          <span class="t1">美化版界面</span>
        </span>
        <span class="arrow">›</span>
      </a>

      <a class="opt official" href="__OFFICIAL__">
        <span class="ic">
          <svg viewBox="0 0 24 24"><path d="M3 4h18v12H8l-5 4V4zm3 4v2h12V8H6zm0 4v2h8v-2H6z"/></svg>
        </span>
        <span class="txt">
          <span class="t1">官方界面</span>
        </span>
        <span class="arrow">›</span>
      </a>
    </div>
    <div class="foot">Router Management Portal</div>
  </div>

  <div class="mask" id="imask">
    <div class="modal">
      <div class="mhead">
        <span class="mt">iStoreOS 风格化路由设置</span>
        <button class="mb tog" onclick="toggleSmall()" title="__SMALL_NEXT__">__SMALL_LABEL__</button>
        <button class="mb" onclick="goIstoreos()">进入 8080 界面</button>
        <button class="mb ghost" onclick="closeModal()">关闭</button>
      </div>
      <div class="mbody"><iframe id="iframe" src="about:blank"></iframe></div>
      <div class="mtip">如需更换主题 / 背景，可在此调整；点「小字」可隐藏或显示页面内的说明小字；点「进入 8080 界面」继续。</div>
    </div>
  </div>

  <script>
    var QUICKSTART = "__QUICKSTART__";
    var ISTOREOS = "__ISTOREOS__";
    function openQuickstart(e) {
      if (e && e.preventDefault) e.preventDefault();
      var m = document.getElementById("imask");
      var f = document.getElementById("iframe");
      if (f.getAttribute("src") === "about:blank") f.setAttribute("src", QUICKSTART);
      m.className = "mask on";
      return false;
    }
    function closeModal() {
      document.getElementById("imask").className = "mask";
    }
    function goIstoreos() {
      window.open(ISTOREOS, "_blank") || (window.location.href = ISTOREOS);
    }
    /* 小字开关：交给本 CGI 的 ?kp_toggle=1 分支处理，翻转 UCI 后 302 回来。
       这里整页跳转而不是重载 iframe —— 因为偏好是设备级的，回来时按钮文案与
       iframe URL 都会按新的 UCI 值重新渲染，最省事也最不容易状态不同步。 */
    function toggleSmall() {
      window.location.href = "/cgi-bin/portal?kp_toggle=1";
    }
  </script>
</body>
</html>
]]

html = html:gsub("__AUTO__", auto)
html = html:gsub("__SUB__", sub)
html = html:gsub("__BEAUTY__", beauty)
html = html:gsub("__OFFICIAL__", official)
html = html:gsub("__QUICKSTART__", quickstart_frame)
html = html:gsub("__ISTOREOS__", istoreos)
html = html:gsub("__SMALL_LABEL__", small_btn_label)
html = html:gsub("__SMALL_NEXT__", small_btn_next)

io.write("Status: 200 OK\r\n")
io.write("Content-Type: text/html\r\n")
io.write("Cache-Control: no-store\r\n\r\n")
io.write(html)
