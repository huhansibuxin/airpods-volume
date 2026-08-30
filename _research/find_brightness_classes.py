# 枚举 SpringBoard 所有已加载模块的 __objc_classname，筛选亮度/控制中心/slider 相关
import frida, sys

def main():
    mgr = frida.get_device_manager()
    dev = mgr.add_remote_device('127.0.0.1:27042')
    sess = dev.attach('SpringBoard')

    js = r'''
function readCString(addr) {
    var p = ptr(addr);
    var out = [];
    while (true) {
        var b = p.readU8();
        if (b === 0) break;
        out.push(b);
        p = p.add(1);
    }
    return String.fromCharCode.apply(null, out);
}

function stringsAt(addr, size) {
    var data = ptr(addr).readByteArray(size);
    var arr = new Uint8Array(data);
    var out = [];
    var cur = [];
    for (var i = 0; i < arr.length; i++) {
        if (arr[i] === 0) {
            if (cur.length > 0) {
                try {
                    out.push(String.fromCharCode.apply(null, cur));
                } catch (e) {}
                cur = [];
            }
        } else {
            cur.push(arr[i]);
        }
    }
    return out;
}

var hits = [];
Process.enumerateModules().forEach(function (m) {
    try {
        m.enumerateSections().forEach(function (s) {
            if (s.name === '__objc_classname') {
                var ss = stringsAt(s.address, s.size);
                ss.forEach(function (c) {
                    if (/Bright|Slider|CCUI|MRU|Volume|Display|Backlight/i.test(c)) {
                        hits.push(m.name + '::' + c);
                    }
                });
            }
        });
    } catch (e) {}
});

send({type:'classes', hits:hits});
'''
    script = sess.create_script(js)
    script.on('message', lambda m, d: print(m['payload']))
    script.load()
    sys.stdin.read()

if __name__ == '__main__':
    main()
