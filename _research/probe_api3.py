import frida

JS = r'''
rpc.exports = {
    probe: function () {
        var r = {};
        try { r.MemoryKeys = Object.getOwnPropertyNames(Memory).join(','); }
        catch (e) { r.MemoryKeys = 'ERR:' + e; }
        try {
            var p = ptr('0x10');
            var names = ['readByteArray','readCString','readUtf8String','readU8','readU32',
                         'readPointer','readS64','writeByteArray','add','and','sub'];
            var got = [];
            names.forEach(function (k) { got.push(k + '=' + typeof p[k]); });
            r.ptrMethods = got.join(' ');
        } catch (e) { r.ptrMethods = 'ERR:' + e; }
        try {
            var cc = Process.findModuleByName('ControlCenterUI');
            r.modKeys = Object.getOwnPropertyNames(Object.getPrototypeOf(cc)).join(',');
        } catch (e) { r.modKeys = 'ERR:' + e; }
        // 试探：段地址能否直接 readByteArray（NativePointer 实例方法）
        try {
            var cc2 = Process.findModuleByName('ControlCenterUI');
            var sec = null;
            cc2.enumerateSections().forEach(function (s) {
                if (s.name === '__objc_classname') sec = s;
            });
            if (sec) {
                var b = sec.address.readByteArray(Math.min(sec.size, 64));
                r.readTest = b ? ('ok bytes=' + (b.byteLength || b.length)) : 'null';
            } else { r.readTest = 'no-section'; }
        } catch (e) { r.readTest = 'ERR:' + e; }
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
    print('%-16s %s' % (k + ':', v))
sess.detach()
