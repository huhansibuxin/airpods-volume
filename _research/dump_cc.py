# dump ControlCenterUI 模块尺寸相关方法（frida → SpringBoard）
import frida, json, sys

JS = r'''
rpc.exports = {
    dumpcc: function () {
        var out = { loaded: null, classes: {}, sizeMethods: [], settingsClasses: [] };

        // 1) 强制加载 ControlCenterUI 框架（SpringBoard 可能懒加载）
        try {
            Module.load('/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI');
            out.loaded = 'ok';
        } catch (e) {
            out.loaded = 'err: ' + e;
        }
        try {
            Module.load('/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices');
        } catch (e) {}

        // 2) 枚举所有已加载类，只保留 ControlCenter 相关的
        var all = ObjC.enumerateLoadedClassesSync();
        var targets = [];
        for (var owner in all) {
            if (owner.indexOf('ControlCenter') === -1) continue;
            var names = all[owner];
            for (var i = 0; i < names.length; i++) targets.push(names[i]);
        }
        out.classCount = targets.length;

        // 3) 逐个取方法，筛出含 size / Size / Settings / Layout 的
        var seen = {};
        targets.forEach(function (name) {
            if (seen[name]) return;
            seen[name] = true;
            var c;
            try { c = ObjC.classes[name]; } catch (e) { return; }
            if (!c) return;
            var methods = [];
            try { methods = c.$ownMethods; } catch (e) { return; }
            methods.forEach(function (m) {
                var low = m.toLowerCase();
                if (low.indexOf('size') !== -1 || low.indexOf('settings') !== -1) {
                    out.sizeMethods.push(name + '  ' + m);
                }
            });
        });

        // 4) 类名含 Settings / Module 的全部列出来（确认管理器类名）
        targets.forEach(function (name) {
            var low = name.toLowerCase();
            if (low.indexOf('settings') !== -1 || low.indexOf('module') !== -1) {
                out.settingsClasses.push(name);
            }
        });
        out.settingsClasses = out.settingsClasses.sort();
        return out;
    }
};
'''

def main():
    mgr = frida.get_device_manager()
    dev = mgr.add_remote_device('127.0.0.1:27042')
    sess = dev.attach('SpringBoard')
    script = sess.create_script(JS)
    script.load()
    res = script.exports_sync.dumpcc()
    print('框架加载:', res.get('loaded'))
    print('相关类数量:', res.get('classCount'))
    print('\n=== 含 Settings/Module 的类 ===')
    for c in res.get('settingsClasses', []):
        print('  ', c)
    print('\n=== 含 size/settings 的方法 ===')
    for m in res.get('sizeMethods', []):
        print('  ', m)
    sess.detach()

main()
