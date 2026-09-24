#!/usr/bin/env python
# kp_put.py —— 路由器文件上传（dropbear 无 SFTP；单次 stdin 写入超限会被 reset）
# 策略：`cat >> tmp` + 原始字节分块 stdout 无回显；末尾 wc -c + md5sum 双校验后原子落位
# 用法: MSYS_NO_PATHCONV=1 ROUTER_HOST=<ip> ROUTER_PW=xxx python kp_put.py <本地文件> <远端绝对路径> [--exec]
import hashlib, os, sys, paramiko

local, remote = sys.argv[1], sys.argv[2]
do_exec = '--exec' in sys.argv[3:]
raw = open(local, 'rb').read().replace(b'\r\n', b'\n')
md5_local = hashlib.md5(raw).hexdigest()
CHUNK = 1000

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
host = os.environ.get('ROUTER_HOST') or sys.exit('ROUTER_HOST not set（例: export ROUTER_HOST=192.168.1.1）')
c.connect(host, 22, 'root', os.environ['ROUTER_PW'], timeout=12)

def sh(cmd, timeout=60):
    si, so, se = c.exec_command(cmd, timeout=timeout)
    si.channel.shutdown_write()
    out = so.read().decode('utf-8', 'replace')
    rc = so.channel.recv_exit_status()
    err = se.read().decode('utf-8', 'replace')
    return rc, out.strip(), err.strip()

tmp = remote + '.kpnew'
sh('rm -f %s' % tmp)

for off in range(0, len(raw), CHUNK):
    part = raw[off:off + CHUNK]
    si, so, se = c.exec_command('cat >> %s' % tmp, timeout=60)
    si.write(part); si.flush(); si.channel.shutdown_write()
    so.read()
    rc = so.channel.recv_exit_status()
    if rc != 0:
        print('CHUNK FAIL off=%d rc=%s err=%s' % (off, rc, se.read().decode()[:200]))
        sys.exit(1)

# 双校验
rc, sz, _ = sh("wc -c < %s" % tmp)
rc2, rmd5, _ = sh("md5sum %s | cut -d' ' -f1" % tmp)
print('local: size=%d md5=%s' % (len(raw), md5_local))
print('remote: size=%s md5=%s' % (sz, rmd5))
if sz != str(len(raw)) or rmd5 != md5_local:
    print('!! 校验失败，清理暂存不落位')
    sh('rm -f %s' % tmp); c.close(); sys.exit(1)

sh('cp -f %s %s.kpbak 2>/dev/null' % (remote, remote))
rc, out, err = sh('mv -f %s %s && echo DEPLOYED' % (tmp, remote))
if do_exec:
    sh('chmod +x %s' % remote)
c.close()
print('OK deployed:', remote, '|', out)
