import argparse,bisect,struct
from pathlib import Path
from capstone import Cs,CS_ARCH_ARM64,CS_MODE_ARM
p=argparse.ArgumentParser();p.add_argument('address',nargs='+');p.add_argument('--size',type=lambda x:int(x,0));a=p.parse_args()
b=(Path(__file__).resolve().parents[1]/'analysis/KartDrift-ios-decrypted').read_bytes()
n,sz=struct.unpack_from('<II',b,16);pos=32;starts=[]
for _ in range(n):
 cmd,size=struct.unpack_from('<II',b,pos)
 if cmd==0x26:
  off,length=struct.unpack_from('<II',b,pos+8);cur=0x100000000;value=shift=0
  for ch in b[off:off+length]:
   value|=(ch&127)<<shift
   if ch&128:shift+=7
   else:
    if not value:break
    cur+=value;starts.append(cur);value=shift=0
 pos+=size
md=Cs(CS_ARCH_ARM64,CS_MODE_ARM)
for text in a.address:
 addr=int(text,0);i=bisect.bisect_right(starts,addr)-1;start=starts[i];end=starts[i+1]
 if a.size:start=addr;end=addr+a.size
 print('FUNCTION',hex(start),'end',hex(end),'query',hex(addr))
 for ins in md.disasm(b[start-0x100000000:end-0x100000000],start):print(hex(ins.address),ins.mnemonic,ins.op_str)
