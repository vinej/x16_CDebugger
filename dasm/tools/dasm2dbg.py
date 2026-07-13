#!/usr/bin/env python3
"""dasm2dbg.py -- turn a dasm assembly listing (+ symbol dump) into a
cc65-style .dbg debug-info file that VS64 can load for source-level
debugging.

VS64 picks its debug-info parser purely from the file EXTENSION (.dbg ->
its cc65 parser, a generic key=value reader), independent of how the PRG
was actually built. dasm has no linker and no cc65/VICE debug output, but
its `-l` listing carries file + line + address + emitted bytes, and its
`-s` dump carries label -> address. That is everything VS64's cc65 line
model needs: line -> span -> seg -> address, plus sym -> address.

Usage:
    dasm2dbg.py <listing.lst> <symbols.sym> <out.dbg> <prg-path> [loadaddr]

The PRG's 2-byte load address (default $0801) becomes the CODE segment
base; span offsets are (address - loadaddr).
"""
import sys, os, re

def main():
    lst_path, sym_path, out_path, prg_path = sys.argv[1:5]
    load = int(sys.argv[5], 0) if len(sys.argv) > 5 else 0x0801

    # ---- parse the listing: (file, line) -> (address, nbytes) -----------
    # dasm listing rows:
    #   ------- FILE <name> LEVEL n PASS n     (enter/return to a file)
    #     <lineno>  <addr4hex> <hexbytes...>   <source>   (emits code)
    #     <lineno>  <addr4hex> ????            <source>   (no bytes)
    file_marker = re.compile(r'^-+ FILE (\S+)')
    # lineno, 4-hex address, then a run of "HH " hex byte pairs
    code_row = re.compile(
        r'^\s*(\d+)\s+([0-9a-fA-F]{4})\s+((?:[0-9a-fA-F]{2} )+)')

    cur_file = None
    files = {}                 # path -> id (insertion order)
    lines = []                 # (file_id, lineno, addr, size)
    seen = set()               # (file_id, lineno) already mapped

    def file_id(path):
        if path not in files:
            files[path] = len(files)
        return files[path]

    with open(lst_path, encoding='utf-8', errors='replace') as f:
        for row in f:
            m = file_marker.match(row)
            if m:
                cur_file = m.group(1).replace('\\', '/')
                continue
            if cur_file is None:
                continue
            m = code_row.match(row)
            if not m:
                continue
            lineno = int(m.group(1))
            addr = int(m.group(2), 16)
            nbytes = len(m.group(3).split())
            if lineno == 0:                     # macro-expansion pseudo-line
                continue
            fid = file_id(cur_file)
            key = (fid, lineno)
            if key in seen:                     # first mapping wins
                continue
            seen.add(key)
            lines.append((fid, lineno, addr, nbytes))

    # ---- parse the symbol dump: label -> address ------------------------
    sym_row = re.compile(r'^([A-Za-z_][\w]*)\s+([0-9a-fA-F]{4})\b')
    syms = []
    if os.path.exists(sym_path):
        with open(sym_path, encoding='utf-8', errors='replace') as f:
            for row in f:
                m = sym_row.match(row)
                if m:
                    syms.append((m.group(1), int(m.group(2), 16)))

    # ---- resolve absolute source paths so VS64 can match the editor -----
    base = os.path.dirname(os.path.abspath(lst_path))
    proj = os.path.dirname(base)                # <project>/build/x.lst -> <project>
    # dasm lists library includes relative to the -I dir (src_dasm), and the
    # main source relative to the project root; search both.
    searchdirs = [proj, os.path.join(proj, 'src_dasm'), base]
    def resolve(p):
        for d in searchdirs:
            cand = os.path.normpath(os.path.join(d, p))
            if os.path.exists(cand):
                return cand
        return os.path.normpath(os.path.join(proj, p))

    id_to_path = {i: resolve(p) for p, i in files.items()}

    # ---- emit the .dbg --------------------------------------------------
    code_size = max((a - load + n for _, _, a, n in lines), default=0)
    out = []
    out.append('version\tmajor=2,minor=0')
    out.append(
        'info\tcsym=0,file=%d,lib=0,line=%d,mod=1,scope=1,seg=1,span=%d,sym=%d,type=0'
        % (len(files), len(lines), len(lines), len(syms)))
    for i, path in id_to_path.items():
        sz = os.path.getsize(path) if os.path.exists(path) else 0
        out.append('file\tid=%d,name="%s",size=%d,mtime=0x00000000,mod=0'
                   % (i, path, sz))
    out.append('lib\tid=0,name="dasm"')
    out.append('mod\tid=0,name="%s",file=0' % os.path.basename(prg_path))
    out.append('seg\tid=0,name="CODE",start=0x%06X,size=0x%04X,addrsize=absolute,'
               'type=rw,oname="%s",ooffs=2'
               % (load, code_size, os.path.abspath(prg_path)))
    out.append('scope\tid=0,name="",mod=0,size=%d,span=0' % code_size)
    # spans + lines are 1:1 here (one span per mapped source line)
    for sid, (fid, lineno, addr, nbytes) in enumerate(lines):
        out.append('span\tid=%d,seg=0,start=%d,size=%d,type=0'
                   % (sid, addr - load, nbytes))
    for lid, (fid, lineno, addr, nbytes) in enumerate(lines):
        out.append('line\tid=%d,file=%d,line=%d,span=%d,type=0'
                   % (lid, fid, lineno, lid))
    for yid, (name, addr) in enumerate(syms):
        out.append('sym\tid=%d,name="%s",addrsize=absolute,size=1,scope=0,'
                   'def=0,val=0x%04X,seg=0,type=lab' % (yid, name, addr))

    with open(out_path, 'w', encoding='ascii', newline='\n') as f:
        f.write('\n'.join(out) + '\n')
    print('  %d source lines, %d symbols, %d files -> %s'
          % (len(lines), len(syms), len(files), os.path.basename(out_path)))

if __name__ == '__main__':
    main()
