# 生成 AirPodsVolume 设置入口图标
# 尺寸严格按 TGK 验证过的标准：@1x=29 / @2x=58 / @3x=87
# （⚠️ 不能用 60/120/180，那是 2 倍过大，iOS 会按 @1x 自然尺寸溢出显示 —— 老板之前踩过）
# 纯 Python 生成 PNG（zlib + struct），无需 Pillow。
import zlib, struct, math, os

def write_png(path, size):
    cx = cy = size / 2.0
    radius = size * 0.22          # 圆角半径（与 TGK 一致）

    # ---- 耳机几何：左右两个耳塞 + 向下的柄 ----
    ear_r    = size * 0.125
    ear_y    = size * 0.38
    dx       = size * 0.165
    stem_w   = size * 0.085
    stem_top = ear_y
    stem_bot = size * 0.72

    def in_headphone(x, y):
        for sign in (-1.0, 1.0):
            ex = cx + sign * dx
            if math.hypot(x - ex, y - ear_y) <= ear_r:                 # 耳塞
                return True
            if abs(x - ex) <= stem_w / 2.0 and stem_top <= y <= stem_bot:   # 柄
                return True
            if math.hypot(x - ex, y - stem_bot) <= stem_w / 2.0:       # 柄底圆角
                return True
        return False

    def in_rounded(x, y):
        r = radius
        lim = size - 1 - r
        if x < r and y < r:
            return math.hypot(x - r, y - r) <= r
        if x > lim and y < r:
            return math.hypot(x - lim, y - r) <= r
        if x < r and y > lim:
            return math.hypot(x - r, y - lim) <= r
        if x > lim and y > lim:
            return math.hypot(x - lim, y - lim) <= r
        return True

    # 超采样抗锯齿（小图标硬边会很毛糙）
    def coverage(fn, x, y, n=3):
        hits = 0
        for i in range(n):
            for j in range(n):
                if fn(x + (i + 0.5) / n, y + (j + 0.5) / n):
                    hits += 1
        return hits / float(n * n)

    bg_top    = (88, 196, 250)    # 浅蓝
    bg_bottom = (0, 122, 255)     # 系统蓝

    raw = bytearray()
    for y in range(size):
        raw.append(0)             # filter type 0
        t = (y / float(size - 1)) if size > 1 else 0.0
        br = bg_top[0] + (bg_bottom[0] - bg_top[0]) * t
        bg = bg_top[1] + (bg_bottom[1] - bg_top[1]) * t
        bb = bg_top[2] + (bg_bottom[2] - bg_top[2]) * t
        for x in range(size):
            ca = coverage(in_rounded, x, y)
            if ca <= 0.0:
                raw += bytes((0, 0, 0, 0))
                continue
            hc = coverage(in_headphone, x, y)
            r = int(br * (1 - hc) + 255 * hc)
            g = int(bg * (1 - hc) + 255 * hc)
            b = int(bb * (1 - hc) + 255 * hc)
            raw += bytes((r, g, b, int(255 * ca)))

    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        c += struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
        return c

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as f:
        f.write(png)
    print("wrote %s  %dx%d  %d bytes" % (os.path.basename(path), size, size, len(png)))

out = r"D:\woekbude\airpods-volume\layout\Library\PreferenceLoader\Preferences\AirPodsVolume"
os.makedirs(out, exist_ok=True)
write_png(os.path.join(out, "icon.png"), 29)
write_png(os.path.join(out, "icon@2x.png"), 58)
write_png(os.path.join(out, "icon@3x.png"), 87)
