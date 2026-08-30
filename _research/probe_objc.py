import frida

JS = r'''
rpc.exports = {
    probe: function () {
        return new Promise(function (resolve) {
            var tries = 0;
            function go() {
                tries++;
                var info = {
                    tries: tries,
                    typeofObjC: (typeof ObjC),
                    available: (typeof ObjC !== 'undefined') ? ObjC.available : null,
                };
                if (typeof ObjC !== 'undefined' && ObjC.available) {
                    // ObjC 就绪，数一下能拿到多少类
                    try {
                        var all = ObjC.enumerateLoadedClassesSync();
                        var n = 0;
                        for (var o in all) n += all[o].length;
                        info.totalClasses = n;
                        info.springboardExists = !!ObjC.classes.SpringBoard;
                    } catch (e) { info.err = String(e); }
                    resolve(info);
                } else if (tries > 40) {
                    resolve(info);
                } else {
                    setTimeout(go, 250);
                }
            }
            go();
        });
    }
};
'''

mgr = frida.get_device_manager()
dev = mgr.add_remote_device('127.0.0.1:27042')
sess = dev.attach('SpringBoard')
s = sess.create_script(JS)
s.load()
print(s.exports_sync.probe())
sess.detach()
