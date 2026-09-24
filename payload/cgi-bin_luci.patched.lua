#!/usr/bin/lua

if os.getenv("SERVER_PORT") ~= "8080" then
	io.write("Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found\n")
	return
end

local script_filename = os.getenv("SCRIPT_FILENAME") or (arg and arg[0]) or ""
local instance_root = script_filename:match("^(.*)/www/cgi%-bin/luci$")
if not instance_root or instance_root == "" then
	io.write("Status: 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\nInvalid CGI path\n")
	return
end
local private_viewdir = instance_root .. "/usr/lib/lua/luci/view"

require "luci.cacheloader"
require "luci.sgi.cgi"

local template = require "luci.template"
local parser = require "luci.template.parser"
local original_parse = parser.parse
local shared_view_prefix = template.viewdir .. "/"
function parser.parse(path, ...)
	if path:sub(1, #shared_view_prefix) == shared_view_prefix then
		local name = path:sub(#shared_view_prefix + 1)
		if name:match("^themes/bootstrap/") or
		   name == "admin_status/nradio_details.htm" or
		   name == "admin_status/nradio_8080_sysauth.htm" then
			path = private_viewdir .. "/" .. name
		end
	end
	return original_parse(path, ...)
end

local luci_util = require "luci.util"
if type(luci_util.shellquote) ~= "function" then
	function luci_util.shellquote(value)
		return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
	end
end

local original_httpdispatch = luci.dispatcher.httpdispatch
local original_createtree = luci.dispatcher.createtree

-- The stock system form writes the shared luci.main.mediaurlbase setting.
-- Disable that field only in this CGI, including crafted form submissions.
local cbi = require "luci.cbi"
local original_cbi_load = cbi.load
function cbi.load(model, ...)
	local maps = original_cbi_load(model, ...)
	if model == "admin_system/system" then
		for _, map in ipairs(maps) do
			for _, section in ipairs(map.children or {}) do
				local field = section.fields and section.fields._mediaurlbase
				if field then
					field.parse = function() end
					field.render = function() end
				end
			end
		end
	end
	return maps
end

local function route_node(tree, path)
	local node = tree
	for _, name in ipairs(path) do
		node = type(node) == "table" and node.nodes and node.nodes[name]
		if type(node) ~= "table" then return nil end
	end
	return node
end

local function route_exists(tree, path)
	local node = route_node(tree, path)
	return node ~= nil and node.target ~= nil and not node.hidden
end

local function add_admin_alias(tree, menu, name, title, order, path)
	if not route_exists(tree, path) then
		return
	end
	menu.nodes[name] = {
		nodes = {},
		target = luci.dispatcher.alias(unpack(path)),
		title = title,
		order = order,
		leaf = true
	}
end

local function inject_plugin_menu(tree, admin)
	local native, factory, known = {}, {}, {}
	local menu = { nodes = {}, target = luci.dispatcher.firstchild(), title = "插件", order = 55 }
	for _, group in ipairs({ "services", "vpn" }) do
		local parent = route_node(tree, { "admin", group })
		for name, child in pairs(parent and parent.nodes or {}) do
			if type(child) == "table" and child.target and child.title and not child.hidden then
				local path = { "admin", group, name }
				local title = tostring(child.title)
				native[#native + 1] = { title = title, path = path }
				known[name:lower()] = true
				add_admin_alias(tree, menu, group .. "_" .. name, title, tonumber(child.order) or 100, path)
			end
		end
	end
	for _, item in ipairs({
		{ "ttyd", "Web SSH", { "admin", "system", "ttyd" } },
		{ "docker", "Docker", { "admin", "docker" } }
	}) do
		if not known[item[1]] and route_exists(tree, item[3]) then
			native[#native + 1] = { title = item[2], path = item[3] }
			known[item[1]] = true
			add_admin_alias(tree, menu, item[1], item[2], 200, item[3])
		end
	end
	for _, item in ipairs({
		{ "openvpn", "OpenVPN", { "nradioadv", "system", "openvpnfull" } },
		{ "zerotier", "ZeroTier", { "nradioadv", "system", "zerotier" } },
		{ "openlist", "OpenList", { "nradioadv", "system", "openlist" } },
		{ "mosdns", "MosDNS", { "nradioadv", "system", "mosdns" } },
		{ "ddns-go", "DDNS-GO", { "nradioadv", "system", "ddnsgo" } },
		{ "docker", "Docker", { "nradioadv", "system", "docker" } },
		{ "ttyd", "Web SSH", { "nradioadv", "system", "webssh" } },
		{ "qiyou", "奇游联机宝", { "nradioadv", "system", "qiyou" } },
		{ "leigod", "雷神加速器", { "nradioadv", "system", "leigod" } },
		{ "aibot", "AI 助手", { "nradioadv", "system", "aibot" } },
		{ "fanctrl", "风扇控制", { "nradioadv", "system", "fanctrl" } },
		{ "cpeopt", "5G 连接监听", { "nradioadv", "cellular", "cpeopt" } }
	}) do
		if not known[item[1]] and route_exists(tree, item[3]) then
			factory[#factory + 1] = { title = item[2], path = "/cgi-bin/luci/" .. table.concat(item[3], "/") }
		end
	end
	table.sort(native, function(a, b) return a.title < b.title end)
	luci.dispatcher.context.nradio_8080_links = { native = native, factory = factory }
	if #native + #factory > 0 then
		menu.nodes.overview = {
			nodes = {}, title = "全部插件入口", order = 0, leaf = true,
			target = function()
				require("luci.http").redirect(luci.dispatcher.build_url("admin", "status", "details") .. "#nradio-plugin-links")
			end
		}
		admin.nodes.nradio_plugins = menu
	end
end

local function set_bootstrap_theme(node)
	node.mediaurlbase = "/luci-static/bootstrap"
	for _, child in pairs(node.nodes or {}) do
		if type(child) == "table" then set_bootstrap_theme(child) end
	end
end

function luci.dispatcher.createtree()
	local tree = original_createtree()
	local admin = tree.nodes and tree.nodes.admin
	if admin then
		admin.nodes = admin.nodes or {}
		inject_plugin_menu(tree, admin)
		tree.nodes.nradio = nil
		tree.nodes.nradioadv = nil
		tree.nodes.authcheck = nil
		admin.nodes = admin.nodes or {}
		admin.sysauth_template = "admin_status/nradio_8080_sysauth"
		local status = admin.nodes.status
		if not status then
			status = { nodes = {}, target = luci.dispatcher.firstchild(), title = "状态", order = 10 }
			admin.nodes.status = status
		end
		if status then
			status.nodes = status.nodes or {}
			status.nodes.details = {
				nodes = {},
				target = luci.dispatcher.template("admin_status/nradio_details"),
				title = "设备总览",
				order = 0,
				leaf = true
			}
		end
	end
	set_bootstrap_theme(tree)
	return tree
end

function luci.dispatcher.httpdispatch(request, prefix)
	local config = require "luci.config"
	config.main.mediaurlbase = "/luci-static/bootstrap"
	config.themes = { Bootstrap = "/luci-static/bootstrap" }
	return original_httpdispatch(request, prefix)
end

local path_info = os.getenv("PATH_INFO") or ""
local request_method = os.getenv("REQUEST_METHOD") or ""

if request_method == "GET" and (
	path_info == "" or
	path_info == "/" or
	path_info == "/admin" or
	path_info == "/admin/" or
	path_info == "/nradio" or
	path_info:match("^/nradio/") or
	path_info == "/nradioadv" or
	path_info:match("^/nradioadv/")
) then
	io.write("Status: 302 Found\r\n")
	io.write("Location: /cgi-bin/luci/admin/status/details\r\n")
	io.write("Content-Type: text/plain\r\n\r\n")
	return
end

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

luci.dispatcher.indexcache = "/tmp/luci-indexcache-bootstrap"
luci.sgi.cgi.run()
