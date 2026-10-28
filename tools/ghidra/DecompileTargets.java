// Decompile only requested ranges. Addresses use Ghidra virtual addresses,
// including any relocation applied by its executable loader.
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;
import java.io.*;

public class DecompileTargets extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) throw new IllegalArgumentException("output-file address:size ...");
        // Supply only independently verified non-returning callees, including
        // their PLT entry where an unanalysed ELF import does not infer it.
        for (int i = 1; i < args.length; i++) {
            if (!args[i].startsWith("--noreturn=")) continue;
            Address target = toAddr(Long.parseUnsignedLong(args[i].substring(11).replace("0x", ""), 16));
            Function function = getFunctionAt(target);
            if (function == null) function = currentProgram.getFunctionManager().createFunction(null,
                target, new AddressSet(target), SourceType.ANALYSIS);
            function.setNoReturn(true);
        }
        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);
        try (PrintWriter out = new PrintWriter(new File(args[0]))) {
            for (int i = 1; i < args.length; i++) {
                if (args[i].startsWith("--noreturn=")) continue;
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
                // A no-analysis import has labels but often lacks function records
                // for PLT entries and tail-call destinations. Define boundaries so
                // the decompiler does not follow a tail call into unrelated code.
                var instructions = currentProgram.getListing().getInstructions(body, true);
                while (instructions.hasNext()) {
                    var instruction = instructions.next();
                    for (Address target : instruction.getFlows()) {
                        if (!body.contains(target) && getFunctionAt(target) == null &&
                            currentProgram.getMemory().contains(target)) {
                            // An existing enclosing function can own this label.
                            // Leave it intact; a helper target must not abort the
                            // independently requested function's decompilation.
                            if (currentProgram.getFunctionManager().getFunctionContaining(target) == null)
                                currentProgram.getFunctionManager().createFunction(null, target,
                                    new AddressSet(target), SourceType.ANALYSIS);
                        }
                    }
                }
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
