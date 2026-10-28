import argparse
from pathlib import Path
from elftools.elf.elffile import ELFFile
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM

p=argparse.ArgumentParser();p.add_argument('names',nargs='+');a=p.parse_args()
root=Path(__file__).resolve().parents[1]
with (root/'analysis/extracted/config.arm64_v8a.apk/lib/arm64-v8a/libUE4.so').open('rb') as f:
 e=ELFFile(f);sym=e.get_section_by_name('.dynsym');symbols=list(sym.iter_symbols())
 names={s.name:s for s in symbols};byaddr={s['st_value']:s.name for s in symbols if s['st_value']}
 rela=e.get_section_by_name('.rela.plt');plt=e.get_section_by_name('.plt')
 if rela and plt:
  for i,r in enumerate(rela.iter_relocations()):byaddr[plt['sh_addr']+32+i*16]=sym.get_symbol(r['r_info_sym']).name+'@plt'
 segments=[s for s in e.iter_segments() if s['p_type']=='PT_LOAD']
 md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
 for name in a.names:
  s=names.get(name)
  if not s:print('MISSING',name);continue
  start=s['st_value'];size=s['st_size'];print('\nFUNCTION',name,hex(start),size)
  seg=next(x for x in segments if x['p_vaddr']<=start<x['p_vaddr']+x['p_filesz'])
  f.seek(start-seg['p_vaddr']+seg['p_offset']);data=f.read(size)
  for ins in md.disasm(data,start):
   extra=''
   if ins.mnemonic in ('bl','b') and ins.op_str.startswith('#'):
    target=int(ins.op_str[1:],16);extra=byaddr.get(target,'')
   print(f'{ins.address:#x} {ins.mnemonic:8} {ins.op_str:35} {extra}')
