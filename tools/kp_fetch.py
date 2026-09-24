#!/usr/bin/env python
# kp_fetch.py —— LuCI 登录会话抓取器（密码走 ROUTER_PW 环境变量）
# 用法: ROUTER_HOST=<ip> ROUTER_PW=xxx python kp_fetch.py <path> [path2 ...]
import os, sys, urllib.request, urllib.parse, urllib.error, http.cookiejar, re

_host = os.environ.get('ROUTER_HOST') or sys.exit('ROUTER_HOST not set（例: export ROUTER_HOST=192.168.1.1）')
BASE = 'http://%s:%s' % (_host, os.environ.get('ROUTER_PORT', '8080'))
USER = 'root'
pw = os.environ.get('ROUTER_PW') or sys.exit('ROUTER_PW not set')

cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
op.addheaders = [('User-Agent', 'Mozilla/5.0 (kp-fetch)')]

def get(url, data=None):
    """返回 (status, body)；HTTPError 也读出 body"""
    try:
        r = op.open(url, data=data, timeout=15)
        return r.status, r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')

# 1) 登录页（403 正常）
st, login_html = get(BASE + '/cgi-bin/luci/')
m = re.search(r"name=['\"]token['\"]\s+value=['\"]([^'\"]+)", login_html)
token = m.group(1) if m else ''

# 2) 登 录
st, body = get(BASE + '/cgi-bin/luci/', urllib.parse.urlencode({
    'luci_username': USER, 'luci_password': pw, 'token': token,
}).encode())
print('login HTTP', st, '| cookies:', [c.name for c in cj])
if 'sysauth' not in ' '.join(c.name for c in cj) and re.search(r'[Ii]nvalid|错误|失败', body):
    print('!! login may have failed, snippet:', body[:300])

# 3) 抓取目标页
for path in sys.argv[1:]:
    url = BASE + '/cgi-bin/luci' + path
    st, body = get(url)
    print('\n===== %s -> HTTP %s (len %d) =====' % (path, st, len(body)))
    for pat, tag in [
        (r'<title>(.*?)</title>', 'TITLE'),
        (r'(?:<h2[^>]*>)(.*?)(?:</h2>)', 'H2'),
        (r'(?:Lua|traceback|Error)[^\n<]{0,200}', 'ERR'),
    ]:
        for mm in re.findall(pat, body, re.S | re.I)[:5]:
            print(' [%s] %s' % (tag, str(mm).strip()[:200].replace('\n', ' ')))
    low = body.lower()
    idx = low.find('traceback')
    if idx < 0: idx = low.find('error')
    if idx >= 0:
        print('---- error snippet ----')
        print(body[max(0, idx - 400):idx + 1500])
    elif len(body) < 3000:
        print('---- body ----'); print(body)
