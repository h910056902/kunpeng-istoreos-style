#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
鲲鹏 C2000 U —— 「iStoreOS 风格门户」一键安装器 (Windows)

做什么：
  1) 双击运行，弹窗询问路由器地址 / 密码（**不保存任何密码**）
  2) SSH 连上 192.168.66.1（默认），把内置的 portal v3 推上去
  3) 顺带部署自愈守卫 + cron（防 nr_webui 自更新覆写）
  4) 逐项自检并回报结果

设计约束（别改）：
  * 设备**无 base64/od/openssl/xxd** → 二进制只能走 printf 八进制
  * 设备**无 sftp** → 只能 exec_command + 分块写入
  * 大文件要**先 gzip**（14423B → 5273B），否则 SSH 通道会被撑断
  * 密码只存在内存里，落盘文件里一个字符都不留
"""

import base64
import gzip
import os
import sys
import threading
import time
import traceback

APP_TITLE = "鲲鹏 C2000 U · iStoreOS 风格门户安装器"
VERSION = "3.0"

DEFAULT_HOST = "192.168.66.1"
DEFAULT_USER = "root"

PORTAL_MD5 = "9360ce8c9b0421ebb39c11306949861f"
PORTAL_VER = "NRWEBUI_PORTAL=3.0"

PORTAL_DST = "/www/cgi-bin/portal"
MAIN_DST = ("/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/"
            "view/quickstart/main.htm")
GUARD_DST = "/usr/bin/kp-portal-guard.sh"
GOLD_DIR = "/root/kp-portal-gold"

CHUNK_BYTES = 700   # 每块原始字节数（八进制后 x4 字符，保守值防断流）
MAX_RETRY = 5


# ===========================================================================
#  payload 资源（打包进 exe）
# ===========================================================================
def resource_dir():
    """PyInstaller 单文件模式下资源被解到 _MEIPASS。"""
    if getattr(sys, "frozen", False):
        return getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def read_payload(name):
    p = os.path.join(resource_dir(), "payload", name)
    with open(p, "rb") as f:
        return f.read()


# ===========================================================================
#  1Panel / LuCI 无关的纯 SSH 文件下发
# ===========================================================================
class Deployer:
    def __init__(self, host, user, pw, log):
        self.host = host
        self.user = user
        self.pw = pw
        self.log = log          # log(str) 回调
        self.cli = None
        self.notes = []         # 自检结果 (name, ok, detail)

    # ---------- 连接 ----------
    def connect(self):
        import paramiko
        self.log("正在连接 %s:22 …" % self.host)
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(self.host, 22, self.user, self.pw,
                  timeout=15, banner_timeout=25, auth_timeout=25)
        self.cli = c
        self.log("✓ SSH 已连接")

    def close(self):
        try:
            if self.cli:
                self.cli.close()
        except Exception:
            pass

    def _reconnect(self):
        try:
            if self.cli:
                self.cli.close()
        except Exception:
            pass
        import paramiko
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(self.host, 22, self.user, self.pw,
                  timeout=15, banner_timeout=25, auth_timeout=25)
        self.cli = c

    # ---------- 执行 ----------
    def run(self, cmd, timeout=120):
        """执行并返回 stdout+stderr（strip）。"""
        _, o, e = self.cli.exec_command(cmd, timeout=timeout)
        so = o.read().decode("utf-8", "replace")
        se = e.read().decode("utf-8", "replace")
        return (so + se).strip()

    def run_safe(self, cmd, timeout=120, retries=MAX_RETRY):
        """断线自动重连。"""
        last = None
        for i in range(retries):
            try:
                return self.run(cmd, timeout=timeout)
            except Exception as ex:
                last = ex
                self.log("  · 通道异常，重连中 (%d/%d)…" % (i + 1, retries))
                time.sleep(1.5)
                try:
                    self._reconnect()
                except Exception as ex2:
                    last = ex2
        raise last

    # ---------- 二进制下发 ----------
    def push_file(self, data, remote_path, label=""):
        """gzip + printf 八进制分块推进，落地后校验 md5。"""
        import hashlib
        want_md5 = hashlib.md5(data).hexdigest()
        gz = gzip.compress(data, 9)

        self.log("推送 %s（%d B → gz %d B）…" % (label or remote_path,
                                                len(data), len(gz)))
        enc = "".join("\\%03o" % b for b in gz)
        step = CHUNK_BYTES * 4
        chunks = [enc[i:i + step] for i in range(0, len(enc), step)]

        tmpgz = "/tmp/kp-push.gz"
        self.run_safe("rm -f %s" % tmpgz)
        for i, c in enumerate(chunks):
            self.run_safe("printf '%s' >> %s" % (c, tmpgz), timeout=180)
            if (i + 1) % 5 == 0 or i + 1 == len(chunks):
                self.log("  · %d/%d 块" % (i + 1, len(chunks)))

        got_sz = self.run_safe("wc -c < %s" % tmpgz).strip()
        if got_sz != str(len(gz)):
            raise RuntimeError("推送尺寸不符：设备 %s / 本地 %d" % (got_sz, len(gz)))

        self.run_safe("gzip -dc %s > %s.kpnew" % (tmpgz, remote_path))
        got_md5 = self.run_safe("md5sum %s.kpnew | awk '{print $1}'"
                                % remote_path).strip()
        if got_md5 != want_md5:
            raise RuntimeError("md5 不符：%s != %s" % (got_md5, want_md5))

        self.run_safe("mv -f %s.kpnew %s && chmod 755 %s"
                      % (remote_path, remote_path, remote_path))
        self.log("  ✓ %s 已落地（md5 %s）" % (remote_path, got_md5))
        return got_md5

    # ---------- 主流程 ----------
    def deploy(self):
        portal = read_payload("portal.lua")
        guard = read_payload("kp-portal-guard.sh")

        # --- 环境自检 ---
        self.log("")
        self.log("【1/6】环境自检")
        host = self.run_safe("cat /proc/sys/kernel/hostname 2>/dev/null")
        self.log("  主机名 : %s" % host)
        if not self.run_safe("test -d /overlay/nradio-apps && echo YES"):
            raise RuntimeError("未发现 /overlay/nradio-apps —— 这似乎不是鲲鹏 8080 环境")
        self.log("  ✓ 8080 环境存在")

        luci = self.run_safe(
            "test -f /overlay/nradio-apps/openwrt-luci-8080/www/cgi-bin/luci "
            "&& echo YES")
        self.notes.append(("8080 CGI 存在", bool(luci), luci or "缺失"))

        # --- 备份 ---
        self.log("")
        self.log("【2/6】备份现有文件")
        stamp = self.run_safe("date +%Y%m%d_%H%M%S")
        bak = "/root/kp-bak-%s" % stamp
        self.run_safe(
            "mkdir -p %s; "
            "[ -f %s ] && cp -f %s %s/portal.bak; "
            "[ -f %s ] && cp -f %s %s/main.htm.bak; "
            "ls %s" % (bak, PORTAL_DST, PORTAL_DST, bak,
                       MAIN_DST, MAIN_DST, bak, bak))
        self.log("  ✓ 备份目录 %s" % bak)

        # --- 部署 portal ---
        self.log("")
        self.log("【3/6】部署门户 portal v3")
        md5 = self.push_file(portal, PORTAL_DST, "portal v3")
        self.notes.append(("portal 部署", md5 == PORTAL_MD5,
                           "md5 %s" % md5))

        syn = self.run_safe(
            "lua -e \"local f,e=loadfile('%s'); "
            "print(f and 'OK' or ('FAIL '..tostring(e)))\" 2>&1" % PORTAL_DST)
        self.notes.append(("Lua 语法", syn.startswith("OK"), syn))
        self.log("  Lua 语法：%s" % syn)

        # --- 安装守卫 ---
        self.log("")
        self.log("【4/6】安装自愈守卫")
        self.push_file(guard, GUARD_DST, "kp-portal-guard.sh")
        self.run_safe("mkdir -p %s && cp -f %s %s/portal.v3"
                      % (GOLD_DIR, PORTAL_DST, GOLD_DIR))
        self.run_safe("[ -f %s ] && cp -f %s %s/main.htm"
                      % (MAIN_DST, MAIN_DST, GOLD_DIR))
        self.log("  ✓ 金样本 → %s/portal.v3" % GOLD_DIR)

        cron_line = "* * * * * %s >/dev/null 2>&1" % GUARD_DST
        has = self.run_safe("crontab -l 2>/dev/null | grep -c kp-portal-guard")
        if has.strip() == "0":
            self.run_safe(
                "{ crontab -l 2>/dev/null; echo '%s'; } | crontab -"
                % cron_line)
            self.run_safe("/etc/init.d/cron restart >/dev/null 2>&1 || true")
            self.log("  ✓ cron 已注册（每分钟自愈）")
        else:
            self.log("  ✓ cron 已存在（跳过）")

        g = self.run_safe("%s >/dev/null 2>&1; echo rc=$?" % GUARD_DST)
        self.notes.append(("守卫可执行", "rc=0" in g, g))

        # --- 清缓存重启 ---
        self.log("")
        self.log("【5/6】清缓存 + 重启 uhttpd")
        self.run_safe("rm -f /tmp/luci-indexcache; "
                      "rm -rf /tmp/luci-modulecache/*; "
                      "/etc/init.d/uhttpd restart >/dev/null 2>&1; "
                      "sleep 2; echo done")
        self.log("  ✓ 已重启")

        # --- 验收 ---
        self.log("")
        self.log("【6/6】验收自检")
        self._accept()

    def _accept(self):
        p = PORTAL_DST
        m = self.run_safe("md5sum %s | awk '{print $1}'" % p).strip()
        self.notes.append(("portal md5", m == PORTAL_MD5, m))

        v = self.run_safe("grep -o 'NRWEBUI_PORTAL=[0-9.]*' %s | head -1" % p)
        self.notes.append(("portal 版本", v.strip() == PORTAL_VER, v.strip()))

        code = self.run_safe(
            "curl -s -o /dev/null -w '%%{http_code}' "
            "-H 'Host: %s' http://127.0.0.1/cgi-bin/portal" % self.host).strip()
        self.notes.append(("门户 HTTP 200", code == "200", code))

        ir = self.run_safe(
            "curl -s -H 'Host: %s' http://127.0.0.1/cgi-bin/portal "
            "| grep -o 'http://[^\"]*istorerouter' | head -1" % self.host)
        ok_ir = "istorerouter" in ir
        self.notes.append(("弹层指向 iStoreRouter", ok_ir, ir.strip() or "未找到"))

        qs = self.run_safe(
            "curl -s -H 'Host: %s' http://127.0.0.1/cgi-bin/portal "
            "| grep -o 'http://[^\"]*quickstart/' | head -1" % self.host)
        self.notes.append(("高级设置指向 quickstart",
                           "quickstart" in qs, qs.strip() or "未找到"))

        n = self.run_safe(
            "curl -s -H 'Host: %s' http://127.0.0.1/cgi-bin/portal "
            "| grep -c 'istore os风格化' | head -1" % self.host)
        try:
            ok_n = int(n.strip()) >= 1
        except Exception:
            ok_n = False
        self.notes.append(("istore os风格化 卡片存在", ok_n, n.strip()))

        self.run_safe(
            "curl -s -o /dev/null -c /tmp/kpck "
            "--data 'luci_username=root&luci_password=admin' "
            "http://%s:8080/cgi-bin/luci/admin/status/details" % self.host)
        r8080 = self.run_safe(
            "curl -s -b /tmp/kpck -o /dev/null -w '%%{http_code}' "
            "http://%s:8080/cgi-bin/luci/admin/istorerouter" % self.host).strip()
        self.notes.append(("8080 iStoreRouter 可达", r8080 == "200", r8080))

        for name, ok, detail in self.notes:
            self.log("  %s %-26s %s" % ("✓" if ok else "✗", name, detail))

        bad = [n for n, ok, _ in self.notes if not ok]
        return len(bad) == 0


# ===========================================================================
#  UI
# ===========================================================================
def run_gui():
    import tkinter as tk
    from tkinter import ttk, messagebox, scrolledtext

    root = tk.Tk()
    root.title("%s v%s" % (APP_TITLE, VERSION))
    root.geometry("720x540")
    root.minsize(640, 460)

    style = ttk.Style()
    try:
        style.theme_use("vista")
    except Exception:
        pass

    frm = ttk.Frame(root, padding=14)
    frm.pack(fill="both", expand=True)

    ttk.Label(frm, text="路由器地址").grid(row=0, column=0, sticky="w", pady=4)
    e_host = ttk.Entry(frm, width=24)
    e_host.insert(0, DEFAULT_HOST)
    e_host.grid(row=0, column=1, sticky="w", pady=4)

    ttk.Label(frm, text="SSH 用户名").grid(row=0, column=2, sticky="w",
                                          padx=(16, 0), pady=4)
    e_user = ttk.Entry(frm, width=12)
    e_user.insert(0, DEFAULT_USER)
    e_user.grid(row=0, column=3, sticky="w", pady=4)

    ttk.Label(frm, text="密码").grid(row=1, column=0, sticky="w", pady=4)
    e_pw = ttk.Entry(frm, width=24, show="●")
    e_pw.grid(row=1, column=1, sticky="w", pady=4)

    tip = ttk.Label(
        frm, foreground="#666",
        text="密码只在内存中使用，不会写入磁盘、不会保存在 exe 里")
    tip.grid(row=2, column=0, columnspan=4, sticky="w", pady=(0, 8))

    out = scrolledtext.ScrolledText(frm, height=20, wrap="word",
                                    font=("Consolas", 9))
    out.grid(row=4, column=0, columnspan=4, sticky="nsew", pady=(6, 8))
    frm.rowconfigure(4, weight=1)
    frm.columnconfigure(3, weight=1)

    status = ttk.Label(frm, text="就绪", foreground="#297ff3")
    status.grid(row=5, column=0, columnspan=2, sticky="w")

    btn = ttk.Button(frm, text="开始安装", width=14)
    btn.grid(row=5, column=3, sticky="e")

    def log(msg):
        out.insert("end", str(msg) + "\n")
        out.see("end")
        root.update_idletasks()

    done = {"ok": False}

    def work():
        host = e_host.get().strip() or DEFAULT_HOST
        user = e_user.get().strip() or DEFAULT_USER
        pw = e_pw.get()
        if not pw:
            messagebox.showwarning("缺少密码", "请输入路由器 SSH 密码。")
            btn.config(state="normal")
            status.config(text="已取消")
            return

        d = Deployer(host, user, pw, log)
        try:
            d.connect()
            d.deploy()
            ok = True
            for n, o, _ in d.notes:
                if not o:
                    ok = False
            done["ok"] = ok
            log("")
            if ok:
                log("=" * 56)
                log("  安装完成 —— 全部自检通过")
                log("=" * 56)
                log("  门户入口 : http://%s/cgi-bin/portal" % host)
                log("  ├ istore os风格化 → 弹层内嵌 iStoreRouter")
                log("  └ 高级设置        → %s:8080/…/quickstart/" % host)
                log("")
                log("  自愈守卫已启用：nr_webui 自更新覆写门户后，")
                log("  一分钟内会自动打回 v3。")
                status.config(text="安装成功", foreground="#008236")
            else:
                log("=" * 56)
                log("  安装完成，但有项目未通过（见上方 ✗）")
                log("=" * 56)
                status.config(text="有项目未通过", foreground="#e6a23c")
        except Exception as ex:
            log("")
            log("!!! 失败：%s" % ex)
            log(traceback.format_exc())
            status.config(text="安装失败", foreground="#f56c6c")
        finally:
            d.close()
            btn.config(state="normal")
            btn.config(text="重新安装")
            root.update_idletasks()

    def on_click():
        btn.config(state="disabled", text="安装中…")
        status.config(text="正在安装…", foreground="#297ff3")
        out.delete("1.0", "end")
        threading.Thread(target=work, daemon=True).start()

    btn.config(command=on_click)
    e_pw.bind("<Return>", lambda _e: on_click())
    e_pw.focus_set()

    log("=" * 56)
    log("  %s v%s" % (APP_TITLE, VERSION))
    log("=" * 56)
    log("  默认目标：%s（SSH root）" % DEFAULT_HOST)
    log("  输入密码后点「开始安装」。")
    log("")

    root.mainloop()


# ===========================================================================
#  命令行（调试 / 无人值守：从环境变量取密码，绝不进 argv）
# ===========================================================================
def run_cli():
    host = os.environ.get("ROUTER_HOST", DEFAULT_HOST)
    user = os.environ.get("ROUTER_USER", DEFAULT_USER)
    pw = os.environ.get("ROUTER_PW")
    if not pw:
        print("CLI 模式需要环境变量 ROUTER_PW", file=sys.stderr)
        return 2

    # Windows 控制台默认 GBK，打不出 ✓/✗ 这类符号 —— 强制 UTF-8，
    # 失败则退化成 ASCII 标记，绝不能因为日志编码把整个安装搞挂。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    def log(m):
        s = str(m)
        try:
            print(s)
        except UnicodeEncodeError:
            print(s.encode("ascii", "replace").decode("ascii"))
        except Exception:
            pass

    d = Deployer(host, user, pw, log)
    try:
        d.connect()
        d.deploy()
    except Exception as ex:
        print("FAIL:", ex)
        traceback.print_exc()
        return 1
    finally:
        d.close()
    return 0 if all(o for _, o, _ in d.notes) else 1


if __name__ == "__main__":
    if "--cli" in sys.argv:
        sys.exit(run_cli())
    run_gui()
