#!/usr/bin/env python3
"""mads2dbg.py -- turn a MADS (Mad Assembler) listing (+ label dump) into a
cc65-style .dbg debug-info file that VS64 can load for source-level
debugging.

VS64 picks its debug-info parser purely from the file EXTENSION (.dbg ->
its cc65 parser, a generic key=value reader), independent of how the PRG
was actually built. MADS has no linker and no cc65/VICE debug output, but
its `-l` listing carries file + line + address + emitted bytes, and its
`-t` dump carries label -> address. That is everything VS64's cc65 line
model needs: line -> span -> seg -> address, plus sym -> address.

Usage:
    mads2dbg.py <listing.lst> <labels.lbl> <out.dbg> <prg-path> [loadaddr]

The PRG's 2-byte load address (default $0801) becomes the CODE segment
base; span offsets are (address - loadaddr).

MADS listing specifics this parser relies on (probed against mads 2.1.7):
  * "Source: <basename>"                  -- enter/return to a file
  * "Macro: <name> [Source: <basename>]"  -- macro body follows, its rows
                                             attributed to <basename>
  * emitting row:  "  <line> <AAAA> HH HH HH<TAB><TAB>source"
      - the 4-hex address and the space-separated byte pairs sit before a
        TAB, so a run of " HH" pairs never bleeds into a mnemonic that
        happens to start with two hex digits (bcc, dec, adc, ...).
      - a long data row is truncated to 6 bytes and marked " + " (no tab);
        its true size is recovered from the next row's address.
  * label dump row:  "<bank><TAB><hexaddr><TAB><name>"  (addr may be wider
    than 16 bits for VRAM constants -- those are dropped).
File basenames are unique across the MADS tree, so each resolves to one
path unambiguously.
"""
import sys, os, re

def main():
    lst_path, lbl_path, out_path, prg_path = sys.argv[1:5]
    load = int(sys.argv[5], 0) if len(sys.argv) > 5 else 0x0801

    # ---- resolve basenames -> absolute source paths ---------------------
    # MADS lists files by basename only ("Source: screen.asm"). Basenames
    # are unique across the tree, so index every .asm under the project.
    base = os.path.dirname(os.path.abspath(lst_path))
    proj = os.path.dirname(base)                # <project>/build/x.lst -> <project>
    name_to_path = {}
    for root in (os.path.join(proj, 'examples'),
                 os.path.join(proj, 'src_mads'),
                 proj):
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, fnames in os.walk(root):
            for fn in fnames:
                if fn.endswith('.asm'):
                    name_to_path.setdefault(fn, os.path.join(dirpath, fn))

    def resolve(basename):
        return name_to_path.get(basename,
                                os.path.normpath(os.path.join(proj, basename)))

    # ---- parse the listing: (file, line) -> (address, nbytes) -----------
    src_marker   = re.compile(r'^Source:\s+(\S+)')
    macro_marker = re.compile(r'^Macro:\s+\S+\s+\[Source:\s+([^\]]+)\]')
    # line, 4-hex address, then a run of " HH" byte pairs (space-separated,
    # terminated by the TAB before the source column).
    emit_row = re.compile(r'^ *(\d+) +([0-9A-Fa-f]{4})((?: [0-9A-Fa-f]{2})+)(.*)$')

    cur_file = None
    files = {}                 # basename -> id (insertion order)
    raw = []                   # (file_id, lineno, addr, nbytes, is_plus)

    def file_id(basename):
        if basename not in files:
            files[basename] = len(files)
        return files[basename]

    # Pin the main source to id 0 (the first EMITTING rows belong to a
    # macro body, so without this macros.asm would claim id 0 and the mod
    # record would name the wrong file).
    main_src = os.path.splitext(os.path.basename(prg_path))[0] + '.asm'
    file_id(main_src)

    with open(lst_path, encoding='utf-8', errors='replace') as f:
        for row in f:
            row = row.rstrip('\n')
            m = macro_marker.match(row)
            if m:
                cur_file = m.group(1)
                continue
            m = src_marker.match(row)
            if m:
                cur_file = m.group(1)
                continue
            if cur_file is None:
                continue
            m = emit_row.match(row)
            if not m:
                continue
            lineno = int(m.group(1))
            addr = int(m.group(2), 16)
            nbytes = len(m.group(3).split())
            is_plus = m.group(4).lstrip().startswith('+')
            raw.append((file_id(cur_file), lineno, addr, nbytes, is_plus))

    # ---- true span size: a truncated (" + ") data row lists only its
    # first 6 bytes, so take its size from the next row's address. -------
    lines = []                 # (file_id, lineno, addr, size)
    seen = set()               # (file_id, lineno) -- first mapping wins
    for i, (fid, lineno, addr, nbytes, is_plus) in enumerate(raw):
        size = nbytes
        if is_plus and i + 1 < len(raw):
            nxt = raw[i + 1][2]
            if nxt > addr:
                size = nxt - addr
        key = (fid, lineno)
        if key in seen:
            continue
        seen.add(key)
        lines.append((fid, lineno, addr, size))

    # ---- parse the label dump: name -> address --------------------------
    # "<bank><TAB><hexaddr><TAB><name>"; keep 16-bit, identifier-named
    # labels (VRAM/constant symbols wider than $FFFF can't be a VICE label
    # or a 16-bit debug address, and aren't needed for source stepping).
    lbl_row = re.compile(r'^[0-9A-Fa-f]{2}\t([0-9A-Fa-f]+)\t([A-Za-z_]\w*)\s*$')
    syms = []
    if os.path.exists(lbl_path):
        with open(lbl_path, encoding='utf-8', errors='replace') as f:
            for row in f:
                m = lbl_row.match(row)
                if not m:
                    continue
                addr = int(m.group(1), 16)
                if addr > 0xFFFF:
                    continue
                syms.append((m.group(2), addr))

    id_to_path = {i: resolve(name) for name, i in files.items()}

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
    out.append('lib\tid=0,name="mads"')
    out.append('mod\tid=0,name="%s",file=0' % os.path.basename(prg_path))
    out.append('seg\tid=0,name="CODE",start=0x%06X,size=0x%04X,addrsize=absolute,'
               'type=rw,oname="%s",ooffs=2'
               % (load, code_size, os.path.abspath(prg_path)))
    out.append('scope\tid=0,name="",mod=0,size=%d,span=0' % code_size)
    # spans + lines are 1:1 here (one span per mapped source line)
    for sid, (fid, lineno, addr, size) in enumerate(lines):
        out.append('span\tid=%d,seg=0,start=%d,size=%d,type=0'
                   % (sid, addr - load, size))
    for lid, (fid, lineno, addr, size) in enumerate(lines):
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
