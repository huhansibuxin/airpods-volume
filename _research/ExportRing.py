# Ghidra headless Python 脚本：导出所有函数反编译
from ghidra.app.decompiler import DecompInterface

outPath = "/mnt/d/woekbude/airpods-volume/_research/ring_decompiled.txt"
di = DecompInterface()
di.openProgram(currentProgram)
fm = currentProgram.getFunctionManager()

with open(outPath, "w") as f:
    for func in fm.getFunctions(True):
        f.write("========== %s @ %s ==========\n" % (func.getName(), func.getEntryPoint()))
        try:
            r = di.decompileFunction(func, 60, monitor)
            if r and r.decompileCompleted():
                f.write(r.getDecompiledFunction().getC())
            else:
                f.write("(反编译失败)\n")
        except Exception as e:
            f.write("(异常: %s)\n" % e)

print("导出完成 -> " + outPath)
