// Decompile only requested ranges. Addresses use Ghidra virtual addresses,
// including any relocation applied by its executable loader.
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.Function;
import java.io.*;

public class DecompileTargets extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) throw new IllegalArgumentException("output-file address:size ...");
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (PrintWriter out = new PrintWriter(new File(args[0]))) {
            for (int i = 1; i < args.length; i++) {
                String[] pair = args[i].split(":");
                long raw = Long.parseUnsignedLong(pair[0].replace("0x", ""), 16);
                Address start = toAddr(raw);
                long size = Long.decode(pair[1]);
                AddressSet body = new AddressSet(start, start.add(size - 1));
                var overlaps = currentProgram.getFunctionManager().getFunctions(body, true);
                java.util.ArrayList<Address> remove = new java.util.ArrayList<>();
                while (overlaps.hasNext()) {
                    Function other = overlaps.next();
                    if (!other.getEntryPoint().equals(start)) remove.add(other.getEntryPoint());
                }
                for (Address entry : remove) currentProgram.getFunctionManager().removeFunction(entry);
                new DisassembleCommand(start, body, true).applyTo(currentProgram, monitor);
                Function function = getFunctionAt(start);
                if (function == null) function = createFunction(start, null);
                if (function == null) { out.println("// Unable to create function at " + start); continue; }
                function.setBody(body);
                decompiler.flushCache();
                DecompileResults result = decompiler.decompileFunction(function, 90, monitor);
                out.println("\n// " + start + " " + function.getName());
                if (result.decompileCompleted()) out.println(result.getDecompiledFunction().getC());
                else out.println("// " + result.getErrorMessage());
                out.flush();
            }
        } finally { decompiler.dispose(); }
    }
}
