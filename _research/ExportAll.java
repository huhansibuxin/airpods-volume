// Ghidra 脚本：反编译所有函数并导出到文件
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import java.io.*;

public class ExportAll extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outPath = "/mnt/d/woekbude/airpods-volume/_research/bettercc_decompiled.txt";
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        PrintWriter pw = new PrintWriter(new File(outPath));

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        int n = 0, ok = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            n++;
            pw.println("========== " + f.getName() + "  @ " + f.getEntryPoint() + " ==========");
            try {
                DecompileResults r = di.decompileFunction(f, 60, monitor);
                if (r != null && r.decompileCompleted()) {
                    pw.println(r.getDecompiledFunction().getC());
                    ok++;
                } else {
                    pw.println("(反编译失败)");
                }
            } catch (Exception e) {
                pw.println("(异常: " + e + ")");
            }
        }
        pw.close();
        println("导出完成: " + ok + "/" + n + " 个函数 -> " + outPath);
    }
}
