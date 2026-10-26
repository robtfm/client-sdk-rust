"""Rename symbols in a COFF object by rewriting its string table.

llvm-objcopy 21 emits NASM-built COFF objects with an empty symbol table, so the
handful of assembly objects whose symbols the prefix map touches are patched here
instead: every mapped name lives in the string table (all are longer than 8 bytes),
and the string table is the last thing in the file, so new names are appended and
the symbol entries repointed.  usage: coff_rename.py <map> <in.o> <out.o>
"""
import struct, sys

mapping = dict(line.split() for line in open(sys.argv[1]) if line.strip())
data = bytearray(open(sys.argv[2], "rb").read())
machine, nsec, _ts, symoff, nsym, _opt, _ch = struct.unpack_from("<HHIIIHH", data, 0)
strtab = symoff + nsym * 18
strsize = struct.unpack_from("<I", data, strtab)[0]
assert strtab + strsize == len(data), "string table is not at the end of the file"
appended = bytearray()
renamed = 0
i = 0
while i < nsym:
    entry = symoff + i * 18
    naux = data[entry + 17]
    zeros, off = struct.unpack_from("<II", data, entry)
    if zeros == 0:
        end = data.index(b"\0", strtab + off)
        name = data[strtab + off:end].decode()
        if name in mapping:
            new = mapping[name].encode() + b"\0"
            struct.pack_into("<II", data, entry, 0, strsize + len(appended))
            appended += new
            renamed += 1
    else:
        name = data[entry:entry + 8].rstrip(b"\0").decode()
        assert name not in mapping, f"short-name symbol {name} needs renaming"
    i += 1 + naux
data += appended
struct.pack_into("<I", data, strtab, strsize + len(appended))
open(sys.argv[3], "wb").write(data)
print(f"{sys.argv[2]}: renamed {renamed}")
