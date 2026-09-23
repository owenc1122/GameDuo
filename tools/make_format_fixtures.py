"""Deterministic format tests; payloads are existing homebrew or public-domain demos."""
from pathlib import Path
import ctypes as c, io, struct, tarfile, zlib, zipfile, hashlib, re
import zstandard
root=Path(__file__).resolve().parent.parent
out=root/'TestFixtures/Formats'
nds=(root/'TestFixtures/TrailMix.nds').read_bytes()
three=(root/'TestFixtures/3DS/Mars3D.3dsx').read_bytes()
cia=(out/'Mars3D.cia').read_bytes()
n64=(out/'InputCPU.n64').read_bytes()
assert n64[:4]==bytes.fromhex('80371240')
(out/'InputCPU.v64').write_bytes(b''.join(n64[i:i+2][::-1] for i in range(0,len(n64),2)))
(out/'InputCPU-little.n64').write_bytes(b''.join(n64[i:i+4][::-1] for i in range(0,len(n64),4)))
# Synthetic routing fixture only: public-domain demo with a MK64-like header, not Mario Kart data.
synthetic=bytearray(n64); synthetic[0x20:0x34]=b'MARIOKART64'.ljust(20,b' ');synthetic[0x3e]=0x45
(out/'SyntheticMK64.v64').write_bytes(b''.join(synthetic[i:i+2][::-1] for i in range(0,len(synthetic),2)))
(out/'FuzedNeo.nds').write_bytes((root/'TestFixtures/FuzedNeo.nds').read_bytes())
(out/'renamed.bin').write_bytes(nds)
(out/'homebrew.srl').write_bytes(nds)
(out/'broken.nds').write_bytes(b'not a game')
(out/'truncated.cia').write_bytes(cia[:100])
(out/'Mars3D.ciax').write_bytes(cia)

def align64(value):
    return (value + 0x3f) & ~0x3f

def cia_with_encrypted_content(data):
    """Set the first TMD content's encrypted flag without adding any keys/data."""
    result=bytearray(data)
    header_size=struct.unpack_from('<I',result,0)[0]
    cert_size,ticket_size=struct.unpack_from('<II',result,8)
    tmd_offset=align64(align64(align64(header_size)+cert_size)+ticket_size)
    signature_type=struct.unpack_from('>I',result,tmd_offset)[0]
    signature_sizes={0x10000:0x200,0x10001:0x100,0x10002:0x3c,
                     0x10003:0x200,0x10004:0x100,0x10005:0x3c}
    body_offset=align64(4+signature_sizes[signature_type])
    first_chunk=tmd_offset+body_offset+0x9c4
    content_type=struct.unpack_from('>H',result,first_chunk+6)[0]
    struct.pack_into('>H',result,first_chunk+6,content_type|1)
    return bytes(result)

encrypted_cia=cia_with_encrypted_content(cia)
(out/'encrypted.ciax').write_bytes(encrypted_cia)
(out/'corrupt.ciax').write_bytes(cia[:0x2020])

def z3ds(data, name):
    frames=[data[i:i+65536] for i in range(0,len(data),65536)]
    compressed=[zstandard.ZstdCompressor(level=3).compress(f) for f in frames]
    table=b''.join(struct.pack('<II',len(z),len(f)) for z,f in zip(compressed,frames))
    table+=struct.pack('<IBI',len(frames),0,0x8F92EAB1)
    stream=b''.join(compressed)+struct.pack('<II',0x184D2A5E,len(table))+table
    (out/name).write_bytes(struct.pack('<4s4sBBHIQQ',b'Z3DS',data[:4],1,0,32,0,len(stream),len(data))+stream)
z3ds(cia,'Mars3D.zcia');z3ds(three,'Mars3D.z3dsx')
z3ds(cia,'Mars3D-Z3DS.ciax');z3ds(encrypted_cia,'encrypted-Z3DS.ciax')
with zipfile.ZipFile(out/'games.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('中文目录/TrailMix.nds',nds);z.writestr('3ds/Mars.3dsx',three);z.writestr('中文目录/assets/data.bin',b'companion data')
with zipfile.ZipFile(out/'nds-save-package.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('FuzedNeo.nds',(out/'FuzedNeo.nds').read_bytes())
    z.writestr('FuzedNeo.sav',bytes([0x5a])*32768)
with zipfile.ZipFile(out/'n64-save-package.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('HelloWorld.n64',(out/'HelloWorld.n64').read_bytes())
    z.writestr('HelloWorld.srm',bytes([0xa5])*32768)
zero_id='0'*32
with zipfile.ZipFile(out/'3ds-save-package.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr(f'sdmc/Nintendo 3DS/{zero_id}/{zero_id}/title/00040000/12345678/data/00000001/main',b'3ds save fixture')
o2r_buffer=io.BytesIO()
with zipfile.ZipFile(o2r_buffer,'w',zipfile.ZIP_DEFLATED) as z:z.writestr('manifest.txt','synthetic test resource')
with zipfile.ZipFile(out/'mixed-mk64.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('game/MK64-3DS.3dsx',three)
    z.writestr('game/content/Mario Kart 64.v64',(out/'SyntheticMK64.v64').read_bytes())
    z.writestr('game/content/mk64.o2r',o2r_buffer.getvalue())
    z.writestr('package/sdmc/3ds/MK64/config/preset.ini','companion data retained')
with tarfile.open(out/'games.tar.gz','w:gz') as t:
    info=tarfile.TarInfo('games/TrailMix.nds');info.size=len(nds);t.addfile(info,io.BytesIO(nds))
with zipfile.ZipFile(out/'traversal.zip','w') as z:z.writestr('../escape.nds',nds)
with zipfile.ZipFile(out/'symlink.zip','w') as z:
    i=zipfile.ZipInfo('link');i.create_system=3;i.external_attr=0o120777<<16;z.writestr(i,'../escape')
with zipfile.ZipFile(out/'nested.zip','w') as z:z.writestr('inside.zip',(out/'games.zip').read_bytes())
with zipfile.ZipFile(out/'empty-games.zip','w') as z:z.writestr('readme.txt','not a game')
with zipfile.ZipFile(out/'corrupt-game.zip','w') as z:z.writestr('bad.nds',b'bad')
lib=c.CDLL('/usr/lib/libarchive.dylib')
for name,args,res in [('archive_write_new',[],c.c_void_p),('archive_write_set_format_7zip',[c.c_void_p],c.c_int),('archive_write_open_filename',[c.c_void_p,c.c_char_p],c.c_int),('archive_entry_new',[],c.c_void_p),('archive_entry_set_pathname',[c.c_void_p,c.c_char_p],None),('archive_entry_set_size',[c.c_void_p,c.c_longlong],None),('archive_entry_set_filetype',[c.c_void_p,c.c_uint],None),('archive_entry_set_perm',[c.c_void_p,c.c_uint],None),('archive_write_header',[c.c_void_p,c.c_void_p],c.c_int),('archive_write_data',[c.c_void_p,c.c_void_p,c.c_size_t],c.c_ssize_t),('archive_write_close',[c.c_void_p],c.c_int),('archive_write_free',[c.c_void_p],c.c_int),('archive_entry_free',[c.c_void_p],None)]:
    f=getattr(lib,name);f.argtypes=args;f.restype=res
w=lib.archive_write_new();assert lib.archive_write_set_format_7zip(w)==0
assert lib.archive_write_open_filename(w,str(out/'games.7z').encode())==0
e=lib.archive_entry_new();lib.archive_entry_set_pathname(e,b'TrailMix.nds');lib.archive_entry_set_size(e,len(nds));lib.archive_entry_set_filetype(e,0o100000);lib.archive_entry_set_perm(e,0o644)
assert lib.archive_write_header(w,e)==0;assert lib.archive_write_data(w,nds,len(nds))==len(nds)
assert lib.archive_write_close(w)==0;lib.archive_entry_free(e);lib.archive_write_free(w)
# RAR4 stored member, enough to test the full RAR->ROM import path.
def rarhead(body):return struct.pack('<H',zlib.crc32(body)&0xffff)+body
name=b'TrailMix.nds'
main=rarhead(struct.pack('<BHHHI',0x73,0,13,0,0))
member=rarhead(struct.pack('<BHHIIBIIBBHI',0x74,0x8000,32+len(name),len(nds),len(nds),3,zlib.crc32(nds),0,20,0x30,len(name),0o100644)+name)
(out/'games.rar').write_bytes(b'Rar!\x1a\x07\x00'+main+member+nds+rarhead(struct.pack('<BHH',0x7b,0,7)))
print('Created',len(list(out.iterdir())),'fixtures')

# Open-source FreeBIOS is used to test system-file routing; no Nintendo BIOS data.
freebios=(root/'ThirdParty/MelonDSDeltaCore/melonDS/src/FreeBIOS.h').read_text()
for cpu in (7,9):
    body=re.search(r'unsigned char bios_arm'+str(cpu)+r'_bin\[\] = \{(.*?)\};',freebios,re.S).group(1)
    (out/f'bios{cpu}.bin').write_bytes(bytes(int(v,16) for v in re.findall(r'0x([0-9a-fA-F]{2})',body)))
with zipfile.ZipFile(out/'bad-system.zip','w') as z:z.writestr('bios9.bin',b'bad')
