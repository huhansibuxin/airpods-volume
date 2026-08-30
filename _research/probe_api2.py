import frida

JS = r'''
rpc.exports = {
    probe: function () {
        var r = {};
        try {
            var m = Process.findModuleByName('libobjc.A.dylib');
            r.libobjc = m ? 'ok base=' + m.base : 'null';
            if (m) {
                r.modFindExport = typeof m.findExportByName;
                r.modGetExport = typeof m.getExportByName;
                r.modEnumSections = typeof m.enumerateSections;
                r.modEnumSymbols = typeof m.enumerateSymbols;
                if (typeof m.findExportByName === 'function') {
                    var a = m.findExportByName('objc_getClassList');
                    r.objc_getClassList = a ? a.toString() : 'null';
                }
            }
        } catch (e) { r.libobjcErr = String(e); }

        // ControlCenterUI 模块
        try {
            var cc = Process.findModuleByName('ControlCenterUI');
            r.cc = cc ? ('ok base=' + cc.base + ' path=' + cc.path) : 'null';
            if (cc && typeof cc.enumerateSections === 'function') {
                var secs = cc.enumerateSections();
                var names = [];
                for (var i = 0; i < secs.length; i++) {
                    var s = secs[i];
                    if (s.name.indexOf('objc') !== -1 || s.name.indexOf('__TEXT') !== -1) {
                        names.push(s.name + ' @' + s.address + ' size=' + s.size);
                    }
                }
                r.ccSections = names;
            }
        } catch (e) { r.ccErr = String(e); }

        r.Process_enumerateModules = typeof Process.enumerateModules;
        r.Module_enumerateSymbols = typeof Module.enumerateSymbols;
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
    if isinstance(v, list):
        print('%-26s' % (k + ':'), '(%d 项)' % len(v))
        for x in v:
            print('    ', x)
    else:
        print('%-26s %s' % (k + ':', v))
sess.detach()
