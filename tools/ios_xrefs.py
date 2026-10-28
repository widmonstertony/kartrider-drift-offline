"""Find ARM64 literal references in the preserved, decrypted main executable."""
import argparse
import struct
from pathlib import Path
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
p=argparse.ArgumentParser();p.add_argument('text');a=p.parse_args()
b=(Path(__file__).resolve().parents[1]/'analysis/KartDrift-ios-decrypted').read_bytes()
targets=set()
for encoding in ('utf-8','utf-16-le','utf-32-le'):
 needle=a.text.encode(encoding);start=0
 while (at:=b.find(needle,start))>=0:
  targets.add(0x100000000+at);print('literal',encoding,hex(at),hex(0x100000000+at));start=at+1
pages={x&~4095 for x in targets}
md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
for i,(w,) in enumerate(struct.iter_unpack('<I',b[:0x6400000])):
 if w&0x9f000000!=0x90000000:continue
 addr=0x100000000+i*4
 imm=((w>>29)&3)|(((w>>5)&0x7ffff)<<2)
 if imm&(1<<20):imm-=1<<21
 page=(addr&~4095)+(imm<<12)
 if page not in pages:continue
 reg=w&31
 for j in range(1,6):
  nxt=struct.unpack_from('<I',b,i*4+j*4)[0]
  if nxt&0xffc00000==0x91000000 and (nxt>>5)&31==reg:
   value=page+((nxt>>10)&0xfff)
   if value in targets:
    print('xref',hex(addr),'to',hex(value))
    for ins in md.disasm(b[i*4-16:i*4+40],addr-16):print(hex(ins.address),ins.mnemonic,ins.op_str)
