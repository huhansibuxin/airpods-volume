#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tweak.xm 编译前自检：括号配对 / @try-@catch 配对 / 禁用语法 / 符号定义顺序。

用法: python check_xm.py [Tweak.xm 路径]
本机没有 theos，推 CI 前先跑一遍，能挡掉大部分"编译失败"往返。
"""
import io
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "Tweak.xm"
src = io.open(path, encoding="utf-8").read()

# 粗略剥离注释与 ObjC 字符串，避免里面的括号干扰计数
t = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
t = re.sub(r"//[^\n]*", "", t)
t = re.sub(r'@"(\\.|[^"\\])*"', '""', t)

ok = True

print("== 括号配对 ==")
for a, b, label in [("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")]:
    na, nb = t.count(a), t.count(b)
    flag = "OK" if na == nb else "!!! MISMATCH"
    if na != nb:
        ok = False
    print("  %s %s=%d %s=%d  %s" % (label, a, na, b, nb, flag))

print("== 异常处理配对 ==")
nt = len(re.findall(r"@try\b", t))
nc = len(re.findall(r"@catch\b", t))
print("  @try=%d @catch=%d  %s" % (nt, nc, "OK" if nt == nc else "!!! MISMATCH"))
if nt != nc:
    ok = False

print("== 硬性禁用语法 ==")
# Logos .xm 是纯 ObjC，@catch(...) 是 C++ 语法，编译必挂
bad_catch = re.findall(r"@catch\s*\(\s*\.\.\.\s*\)", t)
print("  @catch(...) 出现 %d 次（必须为 0）" % len(bad_catch))
if bad_catch:
    ok = False

# 多参数 hook 里的无参 %orig; 会让 Logos 展开失败并级联几十个错
bare = re.findall(r"%orig\s*;", t)
print("  无参 %%orig; 出现 %d 处（多参数方法里必须写全参数）" % len(bare))
for m in re.finditer(r"%orig\s*;", t):
    line = t[: m.start()].count("\n") + 1
    print("      -> 行 %d" % line)

print("== 符号定义顺序（C 要求先声明后使用）==")
names = [
    "routeLog", "volLog", "volStack", "hfpCallActive",
    "callVolumeGuardTick", "startCallVolumeGuard", "stopCallVolumeGuard",
    "startPollWindow", "stopPoll", "enforceAirPodsRoute", "forceCallToAirPods",
]
for name in names:
    d = re.search(r"^static\s+[\w\s\*]+?\b%s\s*\(" % name, t, re.M)
    fwd = re.search(r"^static\s+[\w\s\*]+?\b%s\s*\(\s*[^;]*?\)\s*;" % name, t, re.M)
    u = re.search(r"\b%s\s*\(" % name, t)
    dpos = d.start() if d else -1
    fpos = fwd.start() if fwd else -1
    upos = u.start() if u else -1
    # 有前向声明就算安全，否则定义必须在首次引用之前
    safe = (fpos >= 0) or (dpos >= 0 and dpos <= upos)
    if not safe:
        ok = False
    print("  %-22s def@%-6s fwd@%-6s firstref@%-6s %s"
          % (name, dpos, fpos, upos, "OK" if safe else "!!! USED BEFORE DECL"))

print()
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
