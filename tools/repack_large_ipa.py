"""Repack a stored device IPA as ZIP64 without extracting or changing contents.

Some retained device zip tools wrap 32-bit offsets beyond 4 GiB. Validate each
local header against its central-directory name, recover the matching offset,
then stream every entry through CRC verification into a new ZIP64 archive.
"""
import argparse
import copy
import hashlib
import json
import shutil
import struct
import zipfile
from pathlib import Path, PurePosixPath


def repack(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError('Preserve the input; use a new output')
    partial=destination.with_name(destination.name+'.partial')
    if partial.exists():
        raise ValueError('Partial output already exists; inspect it first')
    recovered=0
    with zipfile.ZipFile(source) as old,source.open('rb') as raw:
        entries=old.infolist()
        if len({x.filename for x in entries})!=len(entries):
            raise ValueError('Duplicate archive entries')
        for entry in entries:
            path=PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!='Payload':
                raise ValueError('Unexpected IPA member path')
            if entry.compress_type!=zipfile.ZIP_STORED or entry.flag_bits&1:
                raise ValueError('Only unencrypted stored device archives are supported')
            candidates=[]
            for offset in (entry.header_offset,entry.header_offset-(1<<32)):
                if offset<0 or offset>=old.start_dir:continue
                raw.seek(offset);header=raw.read(30)
                if len(header)!=30 or header[:4]!=b'PK\x03\x04':continue
                length=struct.unpack_from('<H',header,26)[0]
                name=raw.read(length).decode('utf-8' if entry.flag_bits&0x800 else 'cp437')
                if name==entry.filename:candidates.append(offset)
            if len(candidates)!=1:
                raise ValueError('Cannot uniquely verify local header: '+entry.filename)
            recovered+=candidates[0]!=entry.header_offset
            entry.header_offset=candidates[0]
        boundary=old.start_dir
        for entry in sorted(entries,key=lambda x:x.header_offset,reverse=True):
            entry._end_offset=boundary;boundary=entry.header_offset
        with zipfile.ZipFile(partial,'w',allowZip64=True) as new:
            for entry in sorted(entries,key=lambda x:x.header_offset):
                target=copy.copy(entry)
                # Let the standard writer generate fresh ZIP64 size/offset data.
                extra=b'';position=0
                while position+4<=len(target.extra):
                    kind,length=struct.unpack_from('<HH',target.extra,position)
                    block=target.extra[position:position+4+length]
                    if len(block)!=4+length:raise ValueError('Truncated extra field')
                    if kind!=1:extra+=block
                    position+=4+length
                target.extra=extra
                with old.open(entry) as src,new.open(target,'w',force_zip64=True) as dst:
                    shutil.copyfileobj(src,dst,4*1024*1024)
        partial.replace(destination)
    digest=hashlib.sha256()
    with destination.open('rb') as stream:
        for block in iter(lambda:stream.read(8*1024*1024),b''):digest.update(block)
    return {'bytes':destination.stat().st_size,'sha256':digest.hexdigest(),
            'entries':len(entries),'recovered_offsets':recovered,'all_input_crcs':'passed'}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source');parser.add_argument('destination')
    args=parser.parse_args()
    print(json.dumps(repack(args.source,args.destination),indent=2))
