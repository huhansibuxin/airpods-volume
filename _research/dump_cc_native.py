# 用 libobjc C API 枚举控制中心类/方法（绕开不可用的 frida ObjC bridge）
import frida

JS = r'''
rpc.exports = {
    dump: function () {
        var res = { loadResult: null, err: null, matchedClasses: [], sizeMethods: [], ccClasses: [] };

        // 1) 把 ControlCenterUI 拉进进程（iOS 系统框架只在 dyld 缓存里）
        var paths = [
            '/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI',
            '/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices',
            '/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit'
        ];
        res.loadResult = [];
        paths.forEach(function (p) {
            try { Module.load(p); res.loadResult.push('ok:' + p.split('/').pop()); }
            catch (e) { res.loadResult.push('fail:' + p.split('/').pop()); }
        });

        // 2) 绑 libobjc C API
        function sym(n) { return Module.findExportByName(null, n) || Module.findExportByName('libobjc.A.dylib', n); }
        var f_getClassList = new NativeFunction(sym('objc_getClassList'), 'int', ['pointer', 'int']);
        var f_getName     = new NativeFunction(sym('class_getName'), 'pointer', ['pointer']);
        var f_copyMethods = new NativeFunction(sym('class_copyMethodList'), 'pointer', ['pointer', 'pointer']);
        var f_methodName  = new NativeFunction(sym('method_getName'), 'pointer', ['pointer']);
        var f_selName     = new NativeFunction(sym('sel_getName'), 'pointer', ['pointer']);
        var f_getMeta     = new NativeFunction(sym('object_getClass'), 'pointer', ['pointer']);
        if (!f_getClassList) { res.err = 'no objc_getClassList'; return res; }

        // 3) 枚举全部类
        var count = f_getClassList(ptr(0), 0);
        var buf = Memory.alloc(count * Process.pointerSize);
        f_getClassList(buf, count);

        var outCount = Memory.alloc(8);
        var KEY = ['ccui', 'controlcenter', 'module'];

        for (var i = 0; i < count; i++) {
            var cls = buf.add(i * Process.pointerSize).readPointer();
            if (cls.isNull()) continue;
            var namePtr = f_getName(cls);
            if (namePtr.isNull()) continue;
            var cname = namePtr.readCString();
            if (!cname) continue;
            var low = cname.toLowerCase();
            var hit = false;
            for (var k = 0; k < KEY.length; k++) { if (low.indexOf(KEY[k]) !== -1) { hit = true; break; } }
            if (!hit) continue;

            res.ccClasses.push(cname);

            // 实例方法
            var methods = f_copyMethods(cls, outCount);
            var n = outCount.readU32();
            for (var m = 0; m < n; m++) {
                var meth = methods.add(m * Process.pointerSize).readPointer();
                var sel = f_methodName(meth);
                var sname = f_selName(sel).readCString();
                if (!sname) continue;
                var slow = sname.toLowerCase();
                if (slow.indexOf('size') !== -1 || slow.indexOf('settings') !== -1) {
                    res.sizeMethods.push('[-] ' + cname + ' ' + sname);
                }
            }
            // 类方法（走 metaclass）
            var meta = f_getMeta(cls);
            if (!meta.isNull()) {
                var cm = f_copyMethods(meta, outCount);
                var cn = outCount.readU32();
                for (var c = 0; c < cn; c++) {
                    var meth2 = cm.add(c * Process.pointerSize).readPointer();
                    var sel2 = f_methodName(meth2);
                    var sname2 = f_selName(sel2).readCString();
                    if (!sname2) continue;
                    var s2low = sname2.toLowerCase();
                    if (s2low.indexOf('size') !== -1 || s2low.indexOf('settings') !== -1) {
                        res.sizeMethods.push('[+] ' + cname + ' ' + sname2);
                    }
                }
            }
        }
        res.ccClasses = res.ccClasses.sort();
        return res;
    }
};
'''

mgr = frida.get_device_manager()
dev = mgr.add_remote_device('127.0.0.1:27042')
sess = dev.attach('SpringBoard')
s = sess.create_script(JS)
s.load()
r = s.exports_sync.dump()

print('框架加载:', r.get('loadResult'))
if r.get('err'):
    print('错误:', r['err'])
print('\n=== 控制中心相关类 (%d) ===' % len(r.get('ccClasses', [])))
for c in r.get('ccClasses', []):
    print('  ', c)
print('\n=== 含 size/settings 的方法 (%d) ===' % len(r.get('sizeMethods', [])))
for m in r.get('sizeMethods', []):
    print('  ', m)
sess.detach()
