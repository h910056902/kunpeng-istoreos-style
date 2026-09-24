#!/usr/bin/env python
# kp_tpl_check.py —— htm 模板 Lua 语法校验（真机 lua）
# <%%> 注释跳过 / <%+inc%> include 跳过 / <% code %> 原样 / <%= expr %> 转 __kp_write(expr)
import os, re, sys, paramiko

htm = sys.argv[1] if len(sys.argv) > 1 else 'kunpeng-istoreos-style/payload/admin_status/nradio_details.htm'
src = open(htm, encoding='utf-8').read()

parts = re.split(r'(<%.*?%>)', src, flags=re.S)
code = []
for p in parts:
    if not (p.startswith('<%') and p.endswith('%>')):
        continue
    body = p[2:-2]
    if body.startswith('#') or body.startswith('+'):
        continue
    if body.startswith('='):
        code.append('__kp_write(' + body[1:] + ')\n')
    else:
        code.append(body + '\n')
lua = 'local function __kp_write(x) end\nlocal function __kp_tpl_wrap__()\n' + ''.join(code) + '\nend\n'

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
host = os.environ.get('ROUTER_HOST') or sys.exit('ROUTER_HOST not set（例: export ROUTER_HOST=192.168.1.1）')
c.connect(host, 22, 'root', os.environ['ROUTER_PW'], timeout=12)
si, so, se = c.exec_command("cat > /tmp/kp_tpl_check.lua; lua -e 'assert(loadfile(\"/tmp/kp_tpl_check.lua\"))' && echo LUA_SYNTAX_OK; rm -f /tmp/kp_tpl_check.lua", timeout=30)
si.write(lua.encode('utf-8'))
si.channel.shutdown_write()
out = so.read().decode()
err = se.read().decode()
c.close()
print(out.strip())
if err.strip():
    print('STDERR:', err.strip()[:600])
    # 落盘失败现场便于定位
    open('kp_tpl_check_fail.lua', 'w', encoding='utf-8').write(lua)
sys.exit(0 if 'LUA_SYNTAX_OK' in out else 1)
