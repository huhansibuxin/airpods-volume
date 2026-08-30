# 用 libobjc C API 精确枚举 CCUI*/CCS* 类的方法（类名→方法名对应）
# 注意：这台设备的精简 frida runtime 没有 ObjC / Memory.readByteArray / Module.findExportByName，
# 但 Module 实例的 findExportByName、NativeFunction、Memory.alloc、NativePointer.readByteArray 可用。
import frida

JS = r'''
rpc.exports = {
    dump: function () {
        var res = { classes: {}, err: null };
        var libobjc = Process.findModuleByName('libobjc.A.dylib');
        if (!libobjc) { res.err = 'libobjc not found'; return res; }

        // 解析符号并剥掉 ARM64e PAC 高位（frida 返回的导出地址带 PAC 签名位）
        function A(n) {
            var a = libobjc.findExportByName(n);
            if (!a) throw new Error('symbol not found: ' + n);
            return a.and(ptr('0x0000000FFFFFFFFF'));
        }

        var f_getClassList  = new NativeFunction(A('objc_getClassList'), 'int', ['pointer', 'int']);
        var f_getName       = new NativeFunction(A('class_getName'), 'pointer', ['pointer']);
        var f_copyMethods   = new NativeFunction(A('class_copyMethodList'), 'pointer', ['pointer', 'pointer']);
        var f_methodName    = new NativeFunction(A('method_getName'), 'pointer', ['pointer']);
        var f_selName       = new NativeFunction(A('sel_getName'), 'pointer', ['pointer']);
        var f_getMeta       = new NativeFunction(A('object_getClass'), 'pointer', ['pointer']);

        var count = f_getClassList(ptr(0), 0);
        var buf = Memory.alloc((count + 16) * Process.pointerSize);
        f_getClassList(buf, count);

        var outCount = Memory.alloc(8);

        for (var i = 0; i < count; i++) {
            var cls = buf.add(i * Process.pointerSize).readPointer();
            if (cls.isNull()) continue;
            var cname = f_getName(cls).readCString();
            if (!cname) continue;
            // 只关心控制中心模块体系
            if (cname.indexOf('CCUI') !== 0 &&
                cname.indexOf('CCS') !== 0 &&
                cname.indexOf('SBControlCenter') === -1) continue;

            var list = [];
            var methods = f_copyMethods(cls, outCount);
            var n = outCount.readU32();
            for (var m = 0; m < n; m++) {
                var meth = methods.add(m * Process.pointerSize).readPointer();
                list.push(f_selName(f_methodName(meth)).readCString());
            }
            var meta = f_getMeta(cls);
            if (!meta.isNull()) {
                var cm = f_copyMethods(meta, outCount);
                var cn = outCount.readU32();
                for (var c = 0; c < cn; c++) {
                    var m2 = cm.add(c * Process.pointerSize).readPointer();
                    list.push('+' + f_selName(f_methodName(m2)).readCString());
                }
            }
            res.classes[cname] = list;
        }
        return res;
    }
};
'''

KEY = ('size', 'settings', 'setting', 'identifier', 'module')

mgr = frida.get_device_manager()
dev = mgr.add_remote_device('127.0.0.1:27042')
sess = dev.attach('SpringBoard')
s = sess.create_script(JS)
s.load()
r = s.exports_sync.dump()

if r.get('err'):
    print('错误:', r['err'])
else:
    cls = r['classes']
    print('命中类数: %d\n' % len(cls))

    # 1) 先看尺寸/设置相关的类里有什么方法
    focus = [c for c in cls
             if 'Settings' in c or 'Instance' in c or 'Defaults' in c or 'Layout' in c]
    for c in sorted(focus):
        ms = cls[c]
        hits = [m for m in ms if any(k in m.lower() for k in ('size', 'setting', 'identifier'))]
        print('=== %s (%d 个方法, 相关 %d) ===' % (c, len(ms), len(hits)))
        for m in sorted(set(hits)):
            print('    ', m)
        if hits:
            print()

    # 2) 兜底：全部方法里含 size 的一并列出（防漏）
    print('=== 全部命中类里含 size 的方法（去重） ===')
    seen = set()
    for c in sorted(cls):
        for m in cls[c]:
            if 'ize' in m and m not in seen:
                seen.add(m)
                print('    %s  %s' % (c, m))

sess.detach()
