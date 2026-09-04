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
    "startPollWindow", "stopPoll", "enforceAirPodsRoute", "forceCallToAirPods",
    "forceRouteToAirPodsEx", "airPodsInBluetoothDevices", "currentOutputIsAirPods",
    # v1.9.102 播放审计链（MediaRemote 通道）
    "apv_npAuditCore", "apv_npAuditHandle", "apv_mrCB", "installMediaRemoteAudit",
    # 说明：callVolumeGuardTick/startCallVolumeGuard/stopCallVolumeGuard 曾在此清单，
    # 但函数早已从 Tweak.xm 删除 → 脚本恒报 "USED BEFORE DECL" 假 FAIL。
    # 清单以"文件里真实存在的符号"为准，删掉函数时记得同步删这里。
    "apvLogPath", "apvInvalidateLogPath", "apv_probeLogPath", "apv_log_queue",
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

print("== 静态变量/函数指针声明顺序（通用扫描，v1.9.102 CI 漏检教训）==")
# 单行 static 变量声明（含函数指针、char 数组、多声明符）：
#   static void (*sMRReg)(dispatch_queue_t) = NULL;
#   static BOOL gAutoRoute = YES, gStealBack = YES, gStealHFP = YES;
#   static const char kNPTagPlaying[] = "isplaying";
# 对每个声明名检查"首次出现"是否落在声明处之前（字符串/注释已剥离）。
KEYWORDS = {"static", "const", "void", "BOOL", "id", "char", "NSTimeInterval",
            "NSInteger", "NSUInteger", "dispatch_queue_t", "NSString", "float",
            "double", "int", "long", "CFNotificationCenterRef"}
var_decl = re.compile(r"^static\s+([^;\n]+);\s*$", re.M)
seen_vars = {}
for m in var_decl.finditer(t):
    body = m.group(1)
    idents = []
    # 函数指针形式：(*NAME)
    idents += re.findall(r"\(\*\s*([A-Za-z_]\w*)\s*\)", body)
    # 普通形式：名字在 '=' 或 '[' 之前（支持一行多声明符 NAME=x, NAME=y）
    for part in body.split("(")[0].split(","):
        hits = re.findall(r"([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*=(?!=)", part)
        if hits:
            idents.append(hits[-1])  # 取该段最后一个（声明符名，而非类型名）
    for name in idents:
        if name in KEYWORDS or name in seen_vars:
            continue
        seen_vars[name] = m.start()
for name, dpos in sorted(seen_vars.items()):
    u = re.search(r"\b%s\b" % name, t)
    upos = u.start() if u else -1
    safe = (upos < 0) or (dpos <= upos)
    if not safe:
        ok = False
    print("  %-22s decl@%-6s firstref@%-6s %s"
          % (name, dpos, upos, "OK" if safe else "!!! USED BEFORE DECL"))
print("  （共扫描 %d 个 static 变量/函数指针）" % len(seen_vars))

print()
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
