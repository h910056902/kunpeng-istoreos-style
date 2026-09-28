#!/usr/bin/lua
-- NRWEBUI_PORTAL=3.0  (kp: iStoreOS 风格门户；istore os风格化→iStoreRouter，高级设置→8080 quickstart)
--
-- 变更历史（本行以下为鲲鹏 8080 定制增量，非 nr_webui 原厂内容）：
--   1.0  原厂：两个入口（美化版 / 官方界面）
--   1.1  增加第三张卡「istore os风格化」，弹层内嵌 80 端口的 admin/istorerouter
--   1.2  修 1.1 弹错页 -> 弹层改为内嵌 :8080/cgi-bin/luci/admin/quickstart/
--        并新增「小字：显示/隐藏」开关（设备级，偏好存 UCI /etc/config/kp_portal）
--   2.0  重做为 iStoreOS 风格（2026-09-27）：
--        * 视觉对齐 iStoreOS 官方配色：主色 #553afe，辅 #297ff3，深字 #1e1e1e，
--          浅底 #f4f5f7（取自 /www/luci-static/quickstart/style.css 实测分布）
--        * 删除「小字：显示/隐藏」开关与 ?kp_toggle=1 分支
--        * 删除「进入 8080 界面」按钮
--        * 弹层直接内嵌 iStoreRouter
--   3.0  修正入口语义 + 补回「高级设置」（2026-09-27，用户澄清）：
--        * 「istore os风格化」= 第一张卡，点开弹层内嵌 **iStoreRouter**
--          （:8080/cgi-bin/luci/admin/istorerouter）—— 保留登录鉴权
--        * 新增「高级设置」卡片 → **新标签**打开 :8080/cgi-bin/luci/admin/quickstart/
--          （原厂网络向导 / 高级配置页；v1.2 里曾被当成 istoreos 的目标，语义搞反了）
--        * 保留「美化版界面」(:10086) 与「官方界面」(/cgi-bin/luci) 两张原厂卡
--
-- 说明（别改错）：
--   * 本 CGI 无任何自处理分支，纯渲染 + 302 重定向两条路径
--   * kp_portal 配置文件保留不动（仅不再读写）。彻底清理：rm -f /etc/config/kp_portal
local CONF_PATHS = {"/root/webui.conf"}

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

local beauty = string.format("%s://%s:%s/", proto, hostname, conf.port)
local official = string.format("%s://%s/cgi-bin/luci", proto, hostname)
-- ★ 3.0：弹层目标 = iStoreRouter（8080 实例，路由由 KP-ISTOREROUTER-MENU v2 注册）
local istorerouter_url = string.format("%s://%s:8080/cgi-bin/luci/admin/istorerouter", proto, hostname)
-- ★ 3.0：高级设置 = 原厂网络向导 / 高级配置页（8080 实例 quickstart）
local quickstart_url = string.format("%s://%s:8080/cgi-bin/luci/admin/quickstart/", proto, hostname)
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

local html = [[
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">__AUTO__
<title>设备管理入口</title>
<style>
  /* iStoreOS 配色（取自 /luci-static/quickstart/style.css 实测主色） */
  :root {
    --is-primary: #553afe;
    --is-primary-d: #4529d6;
    --is-primary-l: #f0ecff;
    --is-blue: #297ff3;
    --is-blue-l: #eff6ff;
    --is-ink: #1e1e1e;
    --is-ink-2: #5a5f6b;
    --is-ink-3: #8b93a3;
    --is-line: #e5e7eb;
    --is-surface: #f4f5f7;
    --is-white: #ffffff;
    --is-green: #008236;
    --is-red: #f56c6c;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
    background: var(--is-surface);
    color: var(--is-ink);
    display: flex; align-items: center; justify-content: center;
    padding: 24px;
    -webkit-font-smoothing: antialiased;
  }
  .card {
    width: 100%; max-width: 480px;
    background: var(--is-white);
    border-radius: 16px;
    border: 1px solid var(--is-line);
    box-shadow: 0 8px 32px rgba(30, 30, 30, 0.08);
    padding: 40px 32px 28px;
    text-align: center;
  }
  .brand {
    width: 62px; height: 62px; margin: 0 auto 16px;
    border-radius: 16px;
    background: linear-gradient(135deg, #6b52ff 0%, var(--is-primary) 100%);
    display: flex; align-items: center; justify-content: center;
    box-shadow: 0 6px 18px rgba(85, 58, 254, 0.32);
  }
  .brand svg { width: 32px; height: 32px; fill: var(--is-white); }
  h1 { font-size: 22px; font-weight: 600; letter-spacing: .5px; color: var(--is-ink); }
  .sub { margin-top: 8px; font-size: 13px; color: var(--is-ink-3); }

  .opts { display: flex; flex-direction: column; gap: 12px; margin-top: 28px; }
  .opt {
    display: flex; align-items: center; gap: 14px;
    padding: 15px 16px; border-radius: 12px;
    text-decoration: none; color: var(--is-ink);
    border: 1px solid var(--is-line); background: var(--is-white);
    transition: border-color .16s, box-shadow .16s, transform .16s;
    cursor: pointer; font: inherit; text-align: left; width: 100%;
  }
  .opt:hover {
    border-color: #cdc2ff;
    box-shadow: 0 4px 16px rgba(85, 58, 254, 0.12);
    transform: translateY(-1px);
  }
  .opt:active { transform: translateY(0); }
  .opt .ic {
    flex: 0 0 42px; width: 42px; height: 42px; border-radius: 10px;
    display: flex; align-items: center; justify-content: center;
  }
  .opt .ic svg { width: 22px; height: 22px; fill: var(--is-white); }
  .opt.istoreos .ic { background: linear-gradient(135deg, #6b52ff, var(--is-primary)); }
  .opt.advanced .ic { background: linear-gradient(135deg, #2fa36b, #37b57a); }
  .opt.beauty   .ic { background: linear-gradient(135deg, var(--is-blue), #18b6c9); }
  .opt.official .ic { background: linear-gradient(135deg, #7c869c, #a3adc0); }
  .opt .txt { flex: 1; min-width: 0; }
  .opt .t1 { display: block; font-size: 15px; font-weight: 600; }
  .opt .t2 { display: block; font-size: 12px; color: var(--is-ink-3); margin-top: 3px; }
  .opt .arrow { color: #c8cedb; font-size: 19px; line-height: 1; flex: 0 0 auto; }
  .opt.istoreos { border-color: #ddd5ff; background: linear-gradient(180deg, #fbfaff, var(--is-primary-l)); }

  .tag {
    display: inline-block; font-size: 11px; font-weight: 500;
    color: var(--is-primary); background: #e7e1ff;
    border-radius: 5px; padding: 1px 6px; margin-left: 6px;
    vertical-align: middle;
  }
  .foot { margin-top: 24px; font-size: 11px; color: #b3bac8; }

  /* 弹层 */
  .mask {
    display: none; position: fixed; inset: 0;
    background: rgba(30, 30, 30, 0.55);
    z-index: 9999;
    align-items: center; justify-content: center; padding: 20px;
    backdrop-filter: blur(2px);
  }
  .mask.on { display: flex; }
  .modal {
    width: 100%; max-width: 1180px; height: 88vh;
    background: var(--is-white); border-radius: 14px; overflow: hidden;
    display: flex; flex-direction: column;
    box-shadow: 0 24px 64px rgba(0, 0, 0, 0.42);
  }
  .mhead {
    display: flex; align-items: center; gap: 10px;
    padding: 12px 16px; border-bottom: 1px solid var(--is-line);
    background: var(--is-white); flex: 0 0 auto;
  }
  .mhead .dot {
    width: 26px; height: 26px; border-radius: 7px; flex: 0 0 auto;
    background: linear-gradient(135deg, #6b52ff, var(--is-primary));
    display: flex; align-items: center; justify-content: center;
  }
  .mhead .dot svg { width: 14px; height: 14px; fill: var(--is-white); }
  .mhead .mt {
    font-size: 15px; font-weight: 600; color: var(--is-ink);
    flex: 1; text-align: left; letter-spacing: .3px;
  }
  .mhead button {
    border: 1px solid var(--is-line); background: var(--is-white);
    color: var(--is-ink-2); font-size: 13px; font-family: inherit;
    padding: 7px 14px; border-radius: 8px; cursor: pointer;
    transition: background .14s, border-color .14s, color .14s;
  }
  .mhead button:hover { background: var(--is-surface); border-color: #d5d9e0; }
  .mhead button.mb {
    background: var(--is-primary); border-color: var(--is-primary);
    color: var(--is-white);
  }
  .mhead button.mb:hover { background: var(--is-primary-d); border-color: var(--is-primary-d); }
  .mbody { flex: 1; position: relative; background: var(--is-white); }
  .mbody iframe { width: 100%; height: 100%; border: 0; display: block; }
</style>
</head>
<body>
  <div class="card">
    <div class="brand">
      <svg viewBox="0 0 24 24"><path d="M12 2 3 7v10l9 5 9-5V7l-9-5zm0 2.3 6.5 3.6L12 11.5 5.5 7.9 12 4.3zM5 9.6l6 3.4v6.7l-6-3.3V9.6zm14 0v6.4l-6 3.3v-6.7l6-3.4z"/></svg>
    </div>
    <h1>设备管理入口</h1>
    <div class="sub">__SUB__</div>

    <div class="opts">
      <button type="button" class="opt istoreos" onclick="openIR(event)">
        <span class="ic">
          <svg viewBox="0 0 24 24"><path d="M4 5h7v7H4V5zm9 0h7v4h-7V5zM4 14h7v5H4v-5zm9-3h7v8h-7v-8z"/></svg>
        </span>
        <span class="txt">
          <span class="t1">istore os风格化<span class="tag">新</span></span>
          <span class="t2">iStoreOS 风格界面，点开即 iStoreRouter</span>
        </span>
        <span class="arrow">›</span>
      </button>

      <a class="opt advanced" href="__QUICKSTART__" target="_blank" rel="noopener">
        <span class="ic">
          <svg viewBox="0 0 24 24"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54a.48.48 0 0 0-.48-.41h-3.84a.48.48 0 0 0-.48.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96a.48.48 0 0 0-.59.22L2.74 8.87a.48.48 0 0 0 .12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.48-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32a.49.49 0 0 0-.12-.61l-2.01-1.58zM12 15.6A3.6 3.6 0 1 1 12 8.4a3.6 3.6 0 0 1 0 7.2z"/></svg>
        </span>
        <span class="txt">
          <span class="t1">高级设置</span>
          <span class="t2">网络向导与高级配置（新标签打开）</span>
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
        <span class="dot">
          <svg viewBox="0 0 24 24"><path d="M4 5h7v7H4V5zm9 0h7v4h-7V5zM4 14h7v5H4v-5zm9-3h7v8h-7v-8z"/></svg>
        </span>
        <span class="mt">iStoreRouter</span>
        <button class="mb" onclick="closeModal()">关闭</button>
      </div>
      <div class="mbody"><iframe id="iframe" src="about:blank" title="iStoreRouter"></iframe></div>
    </div>
  </div>

  <script>
    var IR_URL = "__ISTOREROUTER__";
    function openIR(e) {
      if (e && e.preventDefault) e.preventDefault();
      var m = document.getElementById("imask");
      var f = document.getElementById("iframe");
      if (f.getAttribute("src") === "about:blank") f.setAttribute("src", IR_URL);
      m.className = "mask on";
      return false;
    }
    function closeModal() {
      document.getElementById("imask").className = "mask";
    }
    /* Esc 关闭弹层 */
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeModal();
    });
    /* 点遮罩空白处关闭（点弹窗内部不关） */
    document.getElementById("imask").addEventListener("click", function (e) {
      if (e.target === this) closeModal();
    });
  </script>
</body>
</html>
]]

html = html:gsub("__AUTO__", auto)
html = html:gsub("__SUB__", sub)
html = html:gsub("__BEAUTY__", beauty)
html = html:gsub("__OFFICIAL__", official)
html = html:gsub("__ISTOREROUTER__", istorerouter_url)
html = html:gsub("__QUICKSTART__", quickstart_url)

io.write("Status: 200 OK\r\n")
io.write("Content-Type: text/html\r\n")
io.write("Cache-Control: no-store\r\n\r\n")
io.write(html)
