import sys,struct,subprocess,re
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import pe_min as pe
def exports_rva(path):
    d=open(path,'rb').read(); e=struct.unpack_from('<I',d,0x3c)[0]; o=e+24
    ddo=o+(112 if struct.unpack_from('<H',d,o)[0]==0x20b else 96)
    er,esz=struct.unpack_from('<II',d,ddo); nsec=struct.unpack_from('<H',d,e+6)[0]; so=o+struct.unpack_from('<H',d,e+20)[0]
    secs=[struct.unpack_from('<8sIIII',d,so+40*i) for i in range(nsec)]
    def r2o(r):
        for n,vs,va,rs,rp in secs:
            if va<=r<va+max(vs,rs): return r-va+rp
    p=r2o(er); nfn,nn,afn,an,ao=struct.unpack_from('<IIIII',d,p+20)
    out={}
    for i in range(nn):
        nm=d[r2o(struct.unpack_from('<I',d,r2o(an)+4*i)[0]):].split(b'\0')[0].decode()
        ordn=struct.unpack_from('<H',d,r2o(ao)+2*i)[0]; out[nm]=struct.unpack_from('<I',d,r2o(afn)+4*ordn)[0]
    return out
def dis(path,rva,maxn=200):
    base=0x180000000+rva
    o=subprocess.run(['objdump','-d','-M','intel','--no-show-raw-insn','--start-address=%#x'%base,'--stop-address=%#x'%(base+0x700),path],capture_output=True,text=True).stdout
    res=[]
    for l in o.splitlines():
        m=re.match(r'\s*([0-9a-f]+):\t(.*)$',l)
        if m: res.append(l.strip())
        if len(res)>=maxn: break
    return res
if __name__=='__main__':
    path=sys.argv[1]; ex=exports_rva(path)
    print([k for k in ex if 'cpu_has' in k or 'score' in k or 'features' in k][:40])
    for name in sys.argv[2:]:
        print('==',name,hex(ex[name])); 
        out=[]
        for l in dis(path,ex[name]):
            out.append(l); 
            if l.split('\t')[1].startswith('ret') : break
        print('\n'.join(out[:60]))
