# dump Mach-O 符号表，重点找 Logos hook 符号（_logos_method$...$类名$方法名）
import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else 'BetterCC.dylib'
data = open(path, 'rb').read()

# FAT 拆 slice
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
        if ct == 0x0100000C:
            if best is None or (cs & 0xFF) == 0x02:
                best = (off, size, cs)
    data = data[best[0]:best[0] + best[1]]

ncmds = struct.unpack('<I', data[16:20])[0]
offs = 32
symoff = nsyms = stroff = None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<II', data[offs:offs + 8])
    if cmd == 0x02:  # LC_SYMTAB
        symoff, nsyms, stroff, strsize = struct.unpack('<IIII', data[offs + 8:offs + 24])
    offs += cmdsize

if symoff is None:
    print('没有符号表 (LC_SYMTAB)')
    sys.exit(0)

print('符号数: %d' % nsyms)
syms = []
for i in range(nsyms):
    e = symoff + i * 16
    n_strx = struct.unpack('<I', data[e:e + 4])[0]
    n_type, n_sect = data[e + 4], data[e + 5]
    n_value = struct.unpack('<Q', data[e + 8:e + 16])[0]
    if n_strx == 0:
        continue
    end = data.index(b'\x00', stroff + n_strx)
    nm = data[stroff + n_strx:end].decode('utf-8', 'ignore')
    syms.append((nm, n_type, n_value))

# Logos hook 符号
logos = [s for s in syms if 'logos' in s[0].lower()]
print('\n=== Logos 相关符号 (%d) ===' % len(logos))
for nm, t, v in logos:
    print('   ', nm)

# 其他有意思的（函数符号，非 ObjC 属性）
others = [s for s in syms
          if not s[0].startswith('_OBJC_') and 'logos' not in s[0].lower()
          and (s[1] & 0x0E) == 0x0E]  # N_SECT 外部定义
print('\n=== 其他函数/数据符号 (%d, 前 60) ===' % len(others))
for nm, t, v in others[:60]:
    print('   ', nm)
