import struct, sys
def parse(path):
    d=open(path,'rb').read()
    e=struct.unpack_from('<I',d,0x3c)[0]
    assert d[e:e+4]==b'PE\0\0'
    mach,nsec,ts,_,_,optsz,chars=struct.unpack_from('<HHIIIHH',d,e+4)
    o=e+24
    magic=struct.unpack_from('<H',d,o)[0]
    ddo=o+(112 if magic==0x20b else 96)
    imp_rva,imp_sz=struct.unpack_from('<II',d,ddo+8)
    exp_rva,exp_sz=struct.unpack_from('<II',d,ddo)
    secs=[]
    so=o+optsz
    for i in range(nsec):
        n,vs,va,rs,rp=struct.unpack_from('<8sIIII',d,so+40*i)
        secs.append((n.rstrip(b'\0').decode(),va,vs,rp,rs))
    def r2o(r):
        for n,va,vs,rp,rs in secs:
            if va<=r<va+max(vs,rs): return r-va+rp
    def cstr(r):
        p=r2o(r); q=d.index(b'\0',p); return d[p:q].decode('latin1')
    imports={}
    if imp_rva:
        p=r2o(imp_rva)
        while True:
            oft,_,_,name,ft=struct.unpack_from('<IIIII',d,p)
            if not name: break
            dll=cstr(name); fns=[]
            t=r2o(oft or ft)
            while True:
                v=struct.unpack_from('<Q',d,t)[0]
                if not v: break
                fns.append('#%d'%(v&0xffff) if v>>63 else cstr((v&0x7fffffff)+2))
                t+=8
            imports[dll]=fns; p+=20
    exports=[]
    if exp_rva:
        p=r2o(exp_rva)
        _,ts2,_,_,_,nbase,nfn,nnames,afn,anames,aord=struct.unpack_from('<IIHHIIIIIII',d,p)
        t=r2o(anames)
        for i in range(nnames):
            exports.append(cstr(struct.unpack_from('<I',d,t+4*i)[0]))
    return dict(machine=hex(mach),ts=ts,chars=hex(chars),secs=secs,imports=imports,exports=exports,data=d)
if __name__=='__main__':
    import datetime
    for f in sys.argv[1:]:
        r=parse(f)
        print('==',f,'machine',r['machine'],'timestamp',datetime.datetime.utcfromtimestamp(r['ts']),'secs',[(s[0],s[2]) for s in r['secs']])
        print(' imports:',{k:len(v) for k,v in r['imports'].items()})
        print(' exports(%d):'%len(r['exports']),r['exports'][:12])
