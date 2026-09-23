# Python 3 port of the relevant parts of mymc (Ross Ridge, public domain):
# Regenerate: python3 make_fixtures.py <this directory>
# lzari.py encoder (with the simple add_suffix_1 matcher), ps2save.save_max_drive, save_ems.
import struct, zlib, sys, os, time, calendar
HIST_LEN=4096; MIN_MATCH_LEN=3; MAX_MATCH_LEN=60
ARITH_BITS=15; Q1=1<<ARITH_BITS; Q2=Q1*2; Q3=Q1*3; Q4=Q1*4; MAX_CUM=Q1-1
MAX_CHAR=256+MAX_MATCH_LEN-MIN_MATCH_LEN+1

class Codec:
    def init(self, decode):
        self.high=Q4; self.low=0
        if decode:
            self.code=0; self.sym_cum=list(range(0,MAX_CHAR+1))
        else:
            self.shifts=0; self.char_to_symbol=list(range(1,MAX_CHAR+1)); self.sym_cum=list(range(MAX_CHAR,-1,-1))
        self.symbol_to_char=[0]+list(range(MAX_CHAR)); self.sym_freq=[0]+[1]*MAX_CHAR
        self.position_cum=[0]*(HIST_LEN+1); a=0
        for i in range(HIST_LEN,0,-1):
            a=a+10000//(200+i); self.position_cum[i-1]=a
    def update_model_encode(self,symbol):
        sf=self.sym_freq; sc=self.sym_cum
        if sc[0]>=MAX_CUM:
            c=0
            for i in range(MAX_CHAR,0,-1):
                sc[i]=c; a=(sf[i]+1)//2; sf[i]=a; c+=a
            sc[0]=c
        freq=sf[symbol]; ns=symbol
        while sf[ns-1]==freq: ns-=1
        if ns!=symbol:
            sw=self.symbol_to_char[ns]; ch=self.symbol_to_char[symbol]
            self.symbol_to_char[ns]=ch; self.symbol_to_char[symbol]=sw
            self.char_to_symbol[ch]=ns; self.char_to_symbol[sw]=symbol
        sf[ns]+=1
        for i in range(ns): sc[i]+=1
    def output_bit(self,bit):
        self.out.append(bit); bit^=1
        for i in range(self.shifts): self.out.append(bit)
        self.shifts=0
    def _norm(self,low,high):
        while True:
            if high<=Q2: self.output_bit(0)
            elif low>=Q2: self.output_bit(1); low-=Q2; high-=Q2
            elif low>=Q1 and high<=Q3: self.shifts+=1; low-=Q1; high-=Q1
            else: break
            low*=2; high*=2
        self.low=low; self.high=high
    def encode_char(self,char):
        low=self.low; high=self.high; sc=self.sym_cum
        symbol=self.char_to_symbol[char]; r=high-low
        high=low+r*sc[symbol-1]//sc[0]; low+=r*sc[symbol]//sc[0]
        self._norm(low,high); self.update_model_encode(symbol)
    def encode_position(self,position):
        pc=self.position_cum; low=self.low; high=self.high; r=high-low
        high=low+r*pc[position]//pc[0]; low+=r*pc[position+1]//pc[0]
        self._norm(low,high)
    def add_suffix_1(self,pos,find):
        if not find: return (None,0)
        src=self.src; mlen=min(1000,self.max_match,len(src)-pos); hs=max(pos-HIST_LEN,0)
        while mlen>=MIN_MATCH_LEN:
            i=src.rfind(src[pos:pos+mlen],hs,pos)
            if i!=-1: return (i,mlen)
            mlen-=1
        return (None,-1)
    def encode(self,src):
        length=len(src)
        if length==0: return b""
        self.out=[]; self.init(False)
        mm=min(MAX_MATCH_LEN,length); self.max_match=mm
        self.src=src=b"\x20"*mm+src; in_pos=mm
        while in_pos<len(src):
            mp,ml=self.add_suffix_1(in_pos,True)
            if ml<MIN_MATCH_LEN: self.encode_char(src[in_pos])
            else:
                self.encode_char(256-MIN_MATCH_LEN+ml); self.encode_position(in_pos-mp-1); in_pos+=ml-1
            in_pos+=1
        self.shifts+=1
        self.output_bit(0 if self.low<Q1 else 1)
        bits=self.out+[0]*((-len(self.out))%8)
        return bytes(int("".join(map(str,bits[i:i+8])),2) for i in range(0,len(bits),8))

def dirent(mode,length,tod,name):
    return struct.pack("<HHL8sLL8sL28x448s",mode,0,length,tod,0,0,tod,0,name.encode())
def tod(when):
    tm=time.gmtime(when+9*3600)
    return struct.pack("<xBBBBBH",tm.tm_sec,tm.tm_min,tm.tm_hour,tm.tm_mday,tm.tm_mon,tm.tm_year)
def round_up(x,n): return (x+n-1)//n*n

def save_ems(dirname,files,when):
    t=tod(when); out=dirent(0x8427,len(files)+2,t,dirname)+dirent(0x8427,0,t,".")+dirent(0x8427,0,t,"..")
    for name,data in files:
        out+=dirent(0x8417,len(data),t,name)+data+b"\0"*(round_up(len(data),1024)-len(data))
    return out
def save_max(dirname,title,files):
    s=b""
    for name,data in files:
        s+=struct.pack("<L32s",len(data),name.encode())+data
        s+=b"\0"*(round_up(len(s)+8,16)-8-len(s))
    comp=Codec().encode(s)
    hdr=struct.pack("<12sL32s32sLLL",b"Ps2PowerSave",0,dirname.encode(),title.encode(),len(comp)+4,len(files),len(s))
    crc=zlib.crc32(comp,zlib.crc32(hdr))
    return struct.pack("<12sL32s32sLLL",b"Ps2PowerSave",crc,dirname.encode(),title.encode(),len(comp)+4,len(files),len(s))+comp, s

def fixture_files():
    iconsys=bytearray(964); iconsys[0:4]=b"PS2D"
    t="テスト".encode("shift_jis"); iconsys[0xC0:0xC0+len(t)]=t
    iconsys[0x104:0x104+8]=b"view.ico"
    assert len(iconsys)==964
    # deterministic pseudo data: repetitive + LCG noise
    x=12345; noise=bytearray()
    for i in range(3000):
        x=(x*1103515245+12345)&0x7fffffff; noise.append((x>>16)&0xff)
    data=(b"GAME DUO PS2 SAVE " * 200) + bytes(noise) + bytes(range(256))*4
    return [("icon.sys",bytes(iconsys)),("view.ico",b"\x00\x00\x01\x00"+bytes(range(200))*3),("BASLUS-20312GAME",data),("empty.bin",b"")]

if __name__=="__main__":
    out=sys.argv[1]; os.makedirs(out,exist_ok=True)
    files=fixture_files()
    when=calendar.timegm((2004,3,15,12,34,56,0,0,0))  # 2004-03-15 12:34:56 UTC
    open(os.path.join(out,"mymc-BASLUS-20312GAME.psu"),"wb").write(save_ems("BASLUS-20312GAME",files,when))
    m,raw=save_max("BASLUS-20312GAME","Test Save",files)
    open(os.path.join(out,"mymc-BASLUS-20312GAME.max"),"wb").write(m)
    print(len(m),len(raw))
