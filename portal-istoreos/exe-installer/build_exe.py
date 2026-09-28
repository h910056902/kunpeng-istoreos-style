#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建「鲲鹏 C2000 U · iStoreOS 风格门户安装器」exe

用法：
    python build_exe.py

产物：
    dist/鲲鹏门户安装器.exe   （单文件、无控制台、双击即用）
"""

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
PORTAL_DIR = os.path.join(SKILL, "portal-istoreos")

NAME = "KunpengPortalInstaller"
EXE_CN = "鲲鹏门户安装器.exe"


def log(m):
    print(">>", m)


def sync_payload():
    """把 portal-istoreos 里的权威源同步到 payload/。"""
    pdir = os.path.join(HERE, "payload")
    os.makedirs(pdir, exist_ok=True)
    pairs = [
        (os.path.join(PORTAL_DIR, "payload", "portal.lua"),
         os.path.join(pdir, "portal.lua")),
        (os.path.join(PORTAL_DIR, "kp-portal-guard.sh"),
         os.path.join(pdir, "kp-portal-guard.sh")),
    ]
    for src, dst in pairs:
        if not os.path.isfile(src):
            raise SystemExit("缺少源文件: %s" % src)
        shutil.copyfile(src, dst)
        log("payload ← %s (%d B)" % (os.path.basename(src),
                                     os.path.getsize(dst)))


def preflight():
    """打包前硬性检查 —— 这些缺失会打出「双击即崩」的废包。"""
    log("预检：%s" % sys.executable)

    # ★ tkinter 必须有：托管版 Python 常常不带，打出来就是 ModuleNotFoundError
    try:
        import tkinter
        log("  ✓ tkinter %s (Tk %s)" % (tkinter.__file__,
                                         getattr(tkinter, "TkVersion", "?")))
    except ImportError:
        raise SystemExit(
            "\n[致命] 当前 Python 没有 tkinter，打出的 exe 双击会报 "
            "'No module named tkinter'。\n"
            "请改用自带 tkinter 的 Python 重新打包，例如 Windows 原生安装版：\n"
            "    python -c \"import tkinter; print('ok')\"   # 先确认\n"
            "    python build_exe.py\n"
            "（本机可用：C:\\Users\\91005\\AppData\\Local\\Microsoft\\"
            "WindowsApps\\python.exe  —— 已确认带 tkinter 8.6）\n")

    try:
        import PyInstaller
        log("  ✓ PyInstaller %s" % PyInstaller.__version__)
    except ImportError:
        raise SystemExit("[致命] 缺少 PyInstaller：pip install pyinstaller")

    try:
        import paramiko
        log("  ✓ paramiko %s" % paramiko.__version__)
    except ImportError:
        raise SystemExit("[致命] 缺少 paramiko：pip install paramiko")


def main():
    preflight()
    sync_payload()

    sep = ";" if os.name == "nt" else ":"
    args = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onefile",
        "--windowed",
        "--name", NAME,
        "--add-data", "payload%s%s" % (sep, "payload"),
        "--hidden-import", "paramiko",
        "--exclude-module", "numpy",
        "--exclude-module", "matplotlib",
        "--exclude-module", "pandas",
        "--exclude-module", "PIL",
        "--exclude-module", "scipy",
        "--exclude-module", "tkinter.test",
        os.path.join(HERE, "kp_portal_installer.py"),
    ]
    log("运行 PyInstaller …")
    r = subprocess.run(args, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit("PyInstaller 失败 (rc=%d)" % r.returncode)

    built = os.path.join(HERE, "dist", NAME + (".exe" if os.name == "nt" else ""))
    if not os.path.isfile(built):
        raise SystemExit("未找到产物: %s" % built)

    final = os.path.join(HERE, "dist", EXE_CN)
    if os.path.abspath(built) != os.path.abspath(final):
        # ⚠️ 用「改名让位」代替 os.remove —— 某些环境（沙箱/安全软件）
        #    会把删除操作拦到回收站并失败，导致整个构建半途炸掉。
        #    改名是纯元数据操作，不会被拦。
        if os.path.exists(final):
            stale = final + ".old"
            if os.path.exists(stale):
                try:
                    os.replace(built, stale)   # 先占用 .old 名，再把旧的挤走
                except OSError:
                    pass
            os.replace(final, stale)           # 旧的 → .old（不删）
            log("旧产物已让位 → %s" % os.path.basename(stale))
        os.replace(built, final)

    size = os.path.getsize(final) / 1024.0 / 1024.0
    log("✓ 产物: %s (%.1f MB)" % (final, size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
