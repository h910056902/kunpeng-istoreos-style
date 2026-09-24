-- KP-SERVICES-MARKER v1 (kunpeng-istoreos-style) —— 服务入口侧栏菜单
-- 插入位置：CGI 包装器 `luci.dispatcher.indexcache = ...` 之前
-- 语义：在包装器自己的 createtree 之上再包一层，追加「服务」菜单（鲲鹏商店 / 1Panel / Docker）
-- 1Panel 地址：直接解析 /usr/local/bin/1pctl 的 ORIGINAL_PORT/ORIGINAL_ENTRANCE 常量，
--              不依赖执行 bash 脚本（CGI 环境下 1pctl 可能不可用）
do
	local _kp_prev_createtree = luci.dispatcher.createtree
	function luci.dispatcher.createtree()
		local tree = _kp_prev_createtree()
		local admin = tree.nodes and tree.nodes.admin
		if admin then
			admin.nodes = admin.nodes or {}
			local http = require "luci.http"
			local function kp_host()
				local name = tostring(http.getenv("SERVER_NAME") or ""):gsub(":%d+$", "")
				if name == "" then
					name = tostring(luci.sys.exec("ip -4 addr show br-lan | grep -m1 -oE 'inet [0-9.]+' | awk '{print $2}'") or "")
					name = name:gsub("%s+", "")
				end
				return name
			end
			local function kp_panel_base()
				local port, ent = "10090", ""
				local f = io.open("/usr/local/bin/1pctl", "r")
				if f then
					local txt = f:read("*a") or ""
					f:close()
					port = txt:match("ORIGINAL_PORT=(%d+)") or port
					ent = txt:match("ORIGINAL_ENTRANCE=([%w%-_]+)") or ""
				end
				local base = "http://" .. kp_host() .. ":" .. port
				if ent ~= "" then base = base .. "/" .. ent end
				return base
			end
			local svc = {
				nodes = {}, target = luci.dispatcher.firstchild(), title = "服务", order = 50
			}
			svc.nodes.kp_store = {
				nodes = {}, title = "鲲鹏商店", order = 1, leaf = true,
				target = function()
					http.redirect("http://" .. kp_host() .. "/cgi-bin/luci/nradioadv/system/appcenter")
				end
			}
			svc.nodes.kp_1panel = {
				nodes = {}, title = "1Panel 面板", order = 2, leaf = true,
				target = function()
					http.redirect(kp_panel_base())
				end
			}
			svc.nodes.kp_docker = {
				nodes = {}, title = "Docker 容器", order = 3, leaf = true,
				target = function()
					http.redirect(kp_panel_base() .. "/containers")
				end
			}
			admin.nodes.kp_services = svc
		end
		return tree
	end
end
