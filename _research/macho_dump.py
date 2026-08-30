# 静态解析 Mach-O：抽 ObjC 类名/方法名/字符串/依赖（无需 class-dump，Windows 可用）
import struct, sys, re

path = sys.argv[1] if len(sys.argv) > 1 else 'BetterCC.dylib'
data = open(path, 'rb').read()

# FAT 通用二进制：拆出 arm64/arm64e slice
if struct.unpack('>I', data[:4])[0] in (0xCAFEBABE, 0xCAFEBABF):
    is64 = struct.unpack('>I', data[:4])[0] == 0xCAFEBABF
    nfat = struct.unpack('>I', data[4:8])[0]
    ent = 28 if is64 else 20
    best = None
    for i in range(nfat):
        o = 8 + i * ent
        ct, cs = struct.unpack('>ii', data[o:o + 8])
        if is64:
            off, size = struct.unpack('>QQ', data[o + 8:o + 24])
        else:
            off, size = struct.unpack('>II', data[o + 8:o + 16])
        # ARM64 = 0x0100000C；ARM64E 的 subtype 带 0x02
        if ct == 0x0100000C:
            if best is None or (cs & 0xFF) == 0x02:
                best = (off, size, cs)
    if not best:
        print('FAT 里没有 arm64 slice')
        sys.exit(1)
    print('FAT: 取 arm64 slice (subtype=0x%x, offset=%d, size=%d)' % (best[2], best[0], best[1]))
    data = data[best[0]:best[0] + best[1]]

magic = struct.unpack('<I', data[:4])[0]
if magic != 0xFEEDFACF:
    print('不是 64 位 Mach-O (magic=0x%x)' % magic)
    sys.exit(1)

cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
    struct.unpack('<iiIIIII', data[4:32])

FT = {1: 'object', 2: 'execute', 6: 'dylib(FMH)', 8: 'dylib_bundle', 9: 'dylib_stub'}
print('文件: %s  大小=%d' % (path, len(data)))
print('类型: %s  cputype=0x%x  cpusubtype=0x%x  ncmds=%d'
      % (FT.get(filetype, filetype), cputype, cpusubtype, ncmds))

offs = 32
sections = {}
dylibs = []
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<II', data[offs:offs + 8])
    if cmd == 0x19:  # LC_SEGMENT_64
        nsects = struct.unpack('<I', data[offs + 64:offs + 68])[0]
        for j in range(nsects):
            so = offs + 72 + j * 80
            sectname = data[so:so + 16].rstrip(b'\x00').decode('utf-8', 'ignore')
            segname = data[so + 16:so + 32].rstrip(b'\x00').decode('utf-8', 'ignore')
            addr, size = struct.unpack('<QQ', data[so + 32:so + 48])
            foff = struct.unpack('<I', data[so + 48:so + 52])[0]
            sections[(segname, sectname)] = (foff, size)
    elif cmd in (0x0C, 0x18, 0x1F, 0x20):  # LC_LOAD_DYLIB / WEAK / REEXPORT / LAZY
        noff = struct.unpack('<I', data[offs + 8:offs + 12])[0]
        nm = data[offs + noff:offs + cmdsize].split(b'\x00')[0].decode('utf-8', 'ignore')
        dylibs.append(nm)
    offs += cmdsize

print('\n=== 依赖的 dylib ===')
for d in dylibs:
    print('   ', d)

def strings_in(seg_sec):
    if seg_sec not in sections:
        return None
    foff, size = sections[seg_sec]
    raw = data[foff:foff + size]
    out = []
    for p in raw.split(b'\x00'):
        if not p:
            continue
        out.append(p.decode('utf-8', 'ignore'))
    return out

for key in [('__TEXT', '__objc_classname'), ('__DATA', '__objc_classname'),
            ('__DATA_CONST', '__objc_classname')]:
    cs = strings_in(key)
    if cs:
        print('\n=== %s (%d 个类名) ===' % (key[1], len(cs)))
        for c in cs:
            print('   ', c)
        break

for key in [('__TEXT', '__objc_methname'), ('__DATA', '__objc_methname'),
            ('__DATA_CONST', '__objc_methname')]:
    ms = strings_in(key)
    if ms:
        print('\n=== %s (%d 个方法名) ===' % (key[1], len(ms)))
        for m in ms:
            print('   ', m)
        break

# 关键字符串：控制中心相关
cstr_key = None
for key in [('__TEXT', '__cstring'), ('__DATA', '__cstring'), ('__DATA_CONST', '__cstring')]:
    if key in sections:
        cstr_key = key
        break
if cstr_key:
    ss = strings_in(cstr_key)
    pat = re.compile(r'(nowplaying|CCUI|CCS|module|Module|size|Size|controlcenter|ControlCenter|mediaremote|Layout)', re.I)
    hits = [s for s in ss if pat.search(s)]
    print('\n=== __cstring 中与控制中心/尺寸相关的字符串 (%d/%d) ===' % (len(hits), len(ss)))
    for s in hits:
        print('   ', s)
    print('\n=== __cstring 全部 (%d 个) ===' % len(ss))
    for s in ss:
        print('   ', s)
