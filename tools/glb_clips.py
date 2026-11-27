"""Fix animation clips inside a hero GLB (after optimize_glb.py + reduce_keyframes.py).

  python3 tools/glb_clips.py hero.glb --rename Old=New,Old2=New2
  python3 tools/glb_clips.py hero.glb --center            # pin Hips x/z to the bind pose in EVERY clip (no sliding / jumping sideways)
  python3 tools/glb_clips.py hero.glb --trim Clip:0.2      # drop the first 0.2 s of a clip
  python3 tools/glb_clips.py hero.glb --cut Clip:5.8       # drop everything after 5.8 s
  python3 tools/glb_clips.py hero.glb --cap Clip:1.0       # max Hips height (stops a move from throwing the hero into the air)
  python3 tools/glb_clips.py hero.glb --face             # turn every clip so the hero's FACE points forward at the start (and the end, if a clip drifts)
  python3 tools/glb_clips.py hero.glb --report             # Hips height + start offset per clip
Edits the file in place. Old data stays in the buffer (a few KB), which is harmless.
"""
import argparse, json, struct
import numpy as np
def load(p):
    b=open(p,'rb').read();jl=struct.unpack('<I',b[12:16])[0];j=json.loads(b[20:20+jl]);o=20+jl;bl=struct.unpack('<I',b[o:o+4])[0]
    return j,bytearray(b[o+8:o+8+bl])
def save(p,j,binb):
    while len(binb)%4: binb+=b'\0'
    j['buffers'][0]['byteLength']=len(binb)
    s=json.dumps(j,separators=(',',':')).encode(); s+=b' '*((4-len(s)%4)%4)
    out=b'glTF'+struct.pack('<II',2,12+8+len(s)+8+len(binb))+struct.pack('<I',len(s))+b'JSON'+s+struct.pack('<I',len(binb))+b'BIN\0'+bytes(binb)
    open(p,'wb').write(out)
NC={'SCALAR':1,'VEC3':3,'VEC4':4}
def read(j,binb,ai):
    a=j['accessors'][ai];bv=j['bufferViews'][a['bufferView']];n=NC[a['type']]
    return np.frombuffer(bytes(binb),np.float32,a['count']*n,bv.get('byteOffset',0)+a.get('byteOffset',0)).reshape(-1,n).copy()
def add(j,binb,arr,typ,minmax=False):
    while len(binb)%4: binb+=b'\0'
    off=len(binb);d=arr.astype(np.float32).tobytes();binb+=d
    j['bufferViews'].append({'buffer':0,'byteOffset':off,'byteLength':len(d)})
    acc={'bufferView':len(j['bufferViews'])-1,'componentType':5126,'count':len(arr),'type':typ}
    if minmax: acc['min']=[float(x) for x in arr.reshape(len(arr),-1).min(0)];acc['max']=[float(x) for x in arr.reshape(len(arr),-1).max(0)]
    j['accessors'].append(acc);return len(j['accessors'])-1
def trim(j,binb,name,t0,hips_ymax=None):
    a=next(x for x in j['animations'] if x['name']==name)
    hi=next(i for i,n in enumerate(j['nodes']) if n.get('name','').endswith('Hips'))
    tgt={id(s):c for c in a['channels'] for s in [a['samplers'][c['sampler']]]}
    for c in a['channels']:
        s=a['samplers'][c['sampler']];t=read(j,binb,s['input'])[:,0];v=read(j,binb,s['output'])
        if len(t)>1:
            k=t>=t0-1e-6
            if not k.any(): k[-1]=True
            if k.sum()==1 or t[k][0]>t0+1e-4:  # keep a key exactly at t0 (use nearest before)
                i0=max(0,np.argmax(k)-1); k[i0]=True
            t=t[k]-max(0.0,t[k][0]); v=v[k]
        else: t=np.maximum(t-t0,0)
        if hips_ymax is not None and c['target']['node']==hi and c['target']['path']=='translation': v[:,1]=np.minimum(v[:,1],hips_ymax)
        s['input']=add(j,binb,t.reshape(-1,1),'SCALAR',True); s['output']=add(j,binb,v,j['accessors'][s['output']]['type'])
def cut_end(j,binb,name,t1):
    a=next(x for x in j['animations'] if x['name']==name)
    for c in a['channels']:
        s=a['samplers'][c['sampler']];t=read(j,binb,s['input'])[:,0];v=read(j,binb,s['output'])
        k=t<=t1+1e-6
        if not k.any(): k[0]=True
        s['input']=add(j,binb,t[k].reshape(-1,1),'SCALAR',True); s['output']=add(j,binb,v[k],j['accessors'][s['output']]['type'])
def clamp_hips(j,binb,name,ymax):
    a=next(x for x in j['animations'] if x['name']==name)
    hi=next(i for i,n in enumerate(j['nodes']) if n.get('name','').endswith('Hips'))
    for c in a['channels']:
        if c['target']['node']==hi and c['target']['path']=='translation':
            s=a['samplers'][c['sampler']];v=read(j,binb,s['output']);v[:,1]=np.minimum(v[:,1],ymax)
            s['output']=add(j,binb,v,'VEC3')
def qmul(a,b):
    x1,y1,z1,w1=a;x2,y2,z2,w2=b
    return np.array([w1*x2+x1*w2+y1*z2-z1*y2,w1*y2-x1*z2+y1*w2+z1*x2,w1*z2+x1*y2-y1*x2+z1*w2,w1*w2-x1*x2-y1*y2-z1*z2])
def yaw_of(q):
    x,y,z,w=q;return np.arctan2(2*(x*z+w*y),1-2*(x*x+y*y))
def face(j,binb):
    """Meshy clips often start with the body turned 30-60 deg away; in the game that makes a hero look away from
    the opponent and spin during cross-fades. Rotate the Hips so the HEAD faces forward (+Z) at the start; if a clip
    ends turned more than 20 deg from where it started, the correction slides along the clip so it ends forward too."""
    N=j['nodes'];hi=hips(j);par={c:i for i,n in enumerate(N) for c in n.get('children',[])}
    head=next(i for i,n in enumerate(N) if n.get('name','').endswith('Head'));chain=[head]
    while chain[-1]!=hi: chain.append(par[chain[-1]])
    chain.reverse()
    for an in j['animations']:
        rot={ch['target']['node']:an['samplers'][ch['sampler']] for ch in an['channels'] if ch['target']['path']=='rotation'}
        def facing(last):
            q=np.array([0,0,0,1.])
            for n in chain:
                r=read(j,binb,rot[n]['output'])[-1 if last else 0] if n in rot else np.array(N[n].get('rotation',[0,0,0,1]))
                q=qmul(q,r)
            return yaw_of(q)
        if hi not in rot: continue
        s=rot[hi];t=read(j,binb,s['input'])[:,0];v=read(j,binb,s['output']);T=max(t[-1],1e-6)
        y0=facing(False);d=(facing(True)-y0+np.pi)%(2*np.pi)-np.pi
        if abs(d)<np.radians(20): d=0
        out=np.empty_like(v)
        for i,(ti,q) in enumerate(zip(t,v)):
            c=-(y0+d*ti/T);out[i]=qmul(np.array([0,np.sin(c/2),0,np.cos(c/2)]),q)
        s['output']=add(j,binb,out,'VEC4')
        print(f"  face {an['name']:<30} start {np.degrees(y0):+5.0f}  drift {np.degrees(d):+5.0f}")
def hips(j):
    return next(i for i,n in enumerate(j['nodes']) if n.get('name','').endswith('Hips'))
def main():
    ap=argparse.ArgumentParser();ap.add_argument('glb')
    ap.add_argument('--rename',default='');ap.add_argument('--center',action='store_true')
    ap.add_argument('--trim',action='append',default=[]);ap.add_argument('--cut',action='append',default=[]);ap.add_argument('--cap',action='append',default=[])
    ap.add_argument('--report',action='store_true');ap.add_argument('--face',action='store_true');a=ap.parse_args()
    j,b=load(a.glb);hi=hips(j);bx,by,bz=j['nodes'][hi].get('translation',[0,0,0])
    for pair in [p for p in a.rename.split(',') if p]:
        o,n=pair.split('=');[x.__setitem__('name',n) for x in j['animations'] if x['name']==o]
    for t in a.trim: c,v=t.rsplit(':',1);trim(j,b,c,float(v))
    for t in a.cut: c,v=t.rsplit(':',1);cut_end(j,b,c,float(v))
    for t in a.cap: c,v=t.rsplit(':',1);clamp_hips(j,b,c,float(v))
    if a.face: face(j,b)
    for an in j['animations']:
        for ch in an['channels']:
            if ch['target']['node']==hi and ch['target']['path']=='translation':
                s=an['samplers'][ch['sampler']];v=read(j,b,s['output'])
                if a.center: v=v.copy();v[:,0]=bx;v[:,2]=bz;s['output']=add(j,b,v,'VEC3')
                if a.report: print(f"{an['name']:<34} hips y {v[:,1].min():.2f}-{v[:,1].max():.2f} (bind {by:.2f})  start offset x {v[0,0]-bx:+.2f} z {v[0,2]-bz:+.2f}")
    if a.rename or a.center or a.trim or a.cut or a.cap or a.face: save(a.glb,j,b);print('saved',a.glb)
if __name__=='__main__': main()
