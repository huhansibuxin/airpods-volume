# 按类名精确 dump 方法（绕开 frida and() 的符号扩展 bug，用字符串切片剥 ARM64e PAC 位）
import frida

JS = r'''
rpc.exports = {
    dump: function (names) {
        var res = { err: null, classes: {} };
        var libobjc = Process.findModuleByName('libobjc.A.dylib');
        if (!libobjc) { res.err = 'libobjc not found'; return res; }

        // 导出地址带 PAC 签名位，不能用 and()（会符号扩展），改用字符串取低 9 位 hex
        function A(n) {
            var a = libobjc.findExportByName(n);
            if (!a) throw new Error('no symbol ' + n);
            var hex = a.toString(16);
            if (hex.length > 9) hex = hex.slice(-9);
            return ptr('0x' + hex);
        }

        var f_getClass     = new NativeFunction(A('objc_getClass'), 'pointer', ['pointer']);
        var f_copyMethods  = new NativeFunction(A('class_copyMethodList'), 'pointer', ['pointer', 'pointer']);
        var f_methodName   = new NativeFunction(A('method_getName'), 'pointer', ['pointer']);
        var f_selName      = new NativeFunction(A('sel_getName'), 'pointer', ['pointer']);
        var f_getMeta      = new NativeFunction(A('object_getClass'), 'pointer', ['pointer']);

        var outCount = Memory.alloc(8);

        names.forEach(function (cn) {
            var cs = Memory.allocUtf8String(cn);
            var cls = f_getClass(cs);
            if (cls.isNull()) { res.classes[cn] = null; return; }

            var list = [];
            var m = f_copyMethods(cls, outCount);
            var n = outCount.readU32();
            for (var i = 0; i < n; i++) {
                var meth = m.add(i * Process.pointerSize).readPointer();
                list.push(f_selName(f_methodName(meth)).readCString());
            }
            var meta = f_getMeta(cls);
            if (!meta.isNull()) {
                var cm = f_copyMethods(meta, outCount);
                var c = outCount.readU32();
                for (var j = 0; j < c; j++) {
                    var m2 = cm.add(j * Process.pointerSize).readPointer();
                    list.push('+' + f_selName(f_methodName(m2)).readCString());
                }
            }
            res.classes[cn] = list;
        });
        return res;
    }
};
'''

NAMES = [
    'CCUIModuleSettings',
    'CCUIModuleSettingsManager',
    'CCUIModuleInstance',
    'CCUIControlCenterDefaults',
    'CCUIModuleInstanceManager',
    'CCUILayoutOptions',
    'CCUIMutableLayoutOptions',
    'CCUIModuleCollectionViewController',
    'CCSModuleSettingsProvider',
    'CCSModuleRepository',
    'CCUILayoutView',
]

mgr = frida.get_device_manager()
dev = mgr.add_remote_device('127.0.0.1:27042')
sess = dev.attach('SpringBoard')
s = sess.create_script(JS)
s.load()
r = s.exports_sync.dump(NAMES)

if r.get('err'):
    print('错误:', r['err'])
for cn in NAMES:
    ms = r['classes'].get(cn)
    if ms is None:
        print('=== %s: 类不存在/未加载 ===' % cn)
        continue
    hits = [m for m in ms if 'ize' in m.lower() or 'etting' in m]
    print('=== %s (%d 方法, size/settings 相关 %d) ===' % (cn, len(ms), len(hits)))
    for m in sorted(set(hits)):
        print('    ', m)
sess.detach()
