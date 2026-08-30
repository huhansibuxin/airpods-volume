# 直接读 ControlCenterUI 的 __objc_methname / __objc_classname 段（明文），无需 libobjc 调用
import frida

JS = r'''
rpc.exports = {
    segs: function (modname) {
        var m = Process.findModuleByName(modname);
        if (!m) return null;
        var out = {};
        m.enumerateSections().forEach(function (s) {
            if (s.name === '__objc_methname' || s.name === '__objc_classname') {
                out[s.name] = { addr: s.address.toString(), size: s.size };
            }
        });
        return out;
    },
    read: function (addrStr, size) {
        // 注意：Memory.readByteArray 在这台精简 frida runtime 里被裁掉了，
        // 但 NativePointer 实例的 readByteArray 可用
        return ptr(addrStr).readByteArray(size);
    }
};
'''

def strings_from(data):
    out = []
    for part in data.split(b'\x00'):
        if not part:
            continue
        try:
            out.append(part.decode('utf-8'))
        except Exception:
            out.append(part.decode('latin-1'))
    return out

mgr = frida.get_device_manager()
dev = mgr.add_remote_device('127.0.0.1:27042')
sess = dev.attach('SpringBoard')
s = sess.create_script(JS)
s.load()

for mod in ['ControlCenterUI', 'ControlCenterServices']:
    segs = s.exports_sync.segs(mod)
    if not segs:
        print('=== %s: 未加载 ===' % mod)
        continue
    print('=== %s ===' % mod)
    for segname in ['__objc_classname', '__objc_methname']:
        if segname not in segs:
            continue
        info = segs[segname]
        data = bytes(s.exports_sync.read(info['addr'], info['size']))
        strs = strings_from(data)
        if segname == '__objc_classname':
            print('  [%s] 共 %d 个类名：' % (segname, len(strs)))
            for x in strs:
                print('     ', x)
        else:
            def is_sel(s):
                # 段里混着属性类型编码（含 = 或 " 或 ,），selector 不会有这些
                if not s or '=' in s or '"' in s or ',' in s:
                    return False
                return True
            cands = [x for x in strs if is_sel(x)]
            hits = [x for x in cands
                    if 'ize' in x or 'ize' in x.lower()
                    or 'ettings' in x or 'Identifier' in x or 'identifier' in x]
            print('  [%s] 共 %d 个方法名，其中 size/settings/layout 相关 %d 个：'
                  % (segname, len(strs), len(hits)))
            for x in sorted(set(hits)):
                print('     ', x)
    print()

sess.detach()
