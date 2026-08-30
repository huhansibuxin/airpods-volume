import frida

JS = r'''
rpc.exports = {
    probe: function () {
        var r = {};
        function t(expr) { try { return eval(expr); } catch (e) { return 'ERR:' + e; } }
        r.Module = typeof Module;
        r.findExportByName = (typeof Module !== 'undefined' && Module.findExportByName) ? 'yes' : 'no';
        r.NativeFunction = typeof NativeFunction;
        r.Process = typeof Process;
        r.Memory = typeof Memory;
        r.ptr = typeof ptr;
        r.ObjC = typeof ObjC;
        r.Module_load = (typeof Module !== 'undefined' && Module.load) ? 'yes' : 'no';
        r.Module_ensureInitialized = (typeof Module !== 'undefined' && Module.ensureInitialized) ? 'yes' : 'no';
        // 试解析 libobjc 符号
        try {
            var a = Module.findExportByName(null, 'objc_getClassList');
            r.objc_getClassList = a ? a.toString() : 'null';
        } catch (e) { r.objc_getClassList = 'ERR:' + e; }
        // 试加载控制中心框架
        try {
            Module.load('/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI');
            r.loadCC = 'ok';
        } catch (e) { r.loadCC = 'ERR:' + e; }
        // libobjc 是否已加载
        try {
            var m = Process.findModuleByName('libobjc.A.dylib');
            r.libobjc = m ? ('loaded base=' + m.base) : 'not-loaded';
        } catch (e) { r.libobjc = 'ERR:' + e; }
        return r;
    }
};
'''

mgr = frida.get_device_manager()
dev = mgr.add_remote_device('127.0.0.1:27042')
sess = dev.attach('SpringBoard')
s = sess.create_script(JS)
s.load()
r = s.exports_sync.probe()
for k, v in r.items():
    print('%-26s %s' % (k + ':', v))
sess.detach()
