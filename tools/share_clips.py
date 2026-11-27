"""Retarget clips between Meshy SmartRig heroes (same bone names, different rest poses).
World-space: G'_T,k(t) = G_D,k(t) * inv(Grest_D,k) * Align_k * Grest_T,k  (Align_k turns the target's rest bone
direction onto the donor's rest direction), local = inv(G'_parent) * G'_k. Hips y scaled by hip height, x/z = bind.
usage: python3 tools/share_clips.py target.glb assets/donor.glb:Clip[=NewName] ...
Take each clip from the hero it was ORIGINALLY made for (most clips in a GLB with the full channel count), run it
BEFORE reduce_keyframes.py (it bakes 30 fps), then --center and --face as usual."""
import sys,numpy as np;import os;sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from glb_clips import load,save,read,add
def samp(t,v,x,rot):
  i=np.searchsorted(t,x)
  if i<=0:return v[0]
  if i>=len(t):return v[-1]
  a=(x-t[i-1])/(t[i]-t[i-1]+1e-9);r=v[i-1]*(1-a)+v[i]*a
  if rot:
    if np.dot(v[i-1],v[i])<0:r=v[i-1]*(1-a)-v[i]*a
    r/=np.linalg.norm(r)
  return r
def q2m(q):
  x,y,z,w=q;return np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],[2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],[2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
def m2q(m):
  t=np.trace(m)
  if t>0:s=np.sqrt(t+1)*2;return np.array([(m[2,1]-m[1,2])/s,(m[0,2]-m[2,0])/s,(m[1,0]-m[0,1])/s,.25*s])
  i=np.argmax(np.diag(m))
  if i==0:s=np.sqrt(1+m[0,0]-m[1,1]-m[2,2])*2;return np.array([.25*s,(m[0,1]+m[1,0])/s,(m[0,2]+m[2,0])/s,(m[2,1]-m[1,2])/s])
  if i==1:s=np.sqrt(1+m[1,1]-m[0,0]-m[2,2])*2;return np.array([(m[0,1]+m[1,0])/s,.25*s,(m[1,2]+m[2,1])/s,(m[0,2]-m[2,0])/s])
  s=np.sqrt(1+m[2,2]-m[0,0]-m[1,1])*2;return np.array([(m[0,2]+m[2,0])/s,(m[1,2]+m[2,1])/s,.25*s,(m[1,0]-m[0,1])/s])
def align(a,b):
  a=a/np.linalg.norm(a);b=b/np.linalg.norm(b);v=np.cross(a,b);c=np.dot(a,b)
  if c<-0.9999:return -np.eye(3)
  K=np.array([[0,-v[2],v[1]],[v[2],0,-v[0]],[-v[1],v[0],0]]);return np.eye(3)+K+K@K/(1+c)
CHILD={'Hips':'Spine','Spine':'Spine1','Spine1':'Spine2','Spine2':'Neck','Neck':'Head','Head':'HeadTop_End','LeftShoulder':'LeftArm','LeftArm':'LeftForeArm','LeftForeArm':'LeftHand','LeftHand':'LeftHandMiddle1',
 'RightShoulder':'RightArm','RightArm':'RightForeArm','RightForeArm':'RightHand','RightHand':'RightHandMiddle1','LeftUpLeg':'LeftLeg','LeftLeg':'LeftFoot','LeftFoot':'LeftToeBase','RightUpLeg':'RightLeg','RightLeg':'RightFoot','RightFoot':'RightToeBase'}
class Rig:
  def __init__(s,j):
    s.j=j;N=j['nodes'];s.N=N;s.par={c:i for i,n in enumerate(N) for c in n.get('children',[])};s.by={n.get('name'):i for i,n in enumerate(N)}
    s.R={i:q2m(np.array(n.get('rotation',[0,0,0,1.]))) for i,n in enumerate(N)}
    s.G={};s.P={}
    def g(i):
      if i in s.G:return
      R=s.R[i];T=np.array(s.N[i].get('translation',[0,0,0.]))*1;Sc=np.array(s.N[i].get('scale',[1,1,1.]))
      if i in s.par:p=s.par[i];g(p);s.G[i]=s.G[p]@R;s.P[i]=s.P[p]+s.Gs[p]@T;s.Gs[i]=s.Gs[p]@(R*Sc)
      else:s.G[i]=R;s.P[i]=T;s.Gs[i]=R*Sc
    s.Gs={}
    for i in range(len(N)):g(i)
  def dir(s,nm):
    c=CHILD.get(nm.split(':')[-1]);
    if not c:return None
    a=s.by.get(nm);b=s.by.get('mixamorig:'+c)
    if a is None or b is None:return None
    return s.P[b]-s.P[a]
tgt=sys.argv[1];j,b=load(tgt);RT=Rig(j);hiT=RT.by['mixamorig:Hips'];hT=np.array(j['nodes'][hiT]['translation'])
cache={}
for spec in sys.argv[2:]:
  path,clip=spec.rsplit(':',1);new=clip
  if '=' in clip:clip,new=clip.split('=')
  if any(a['name']==new for a in j['animations']):print('skip',new);continue
  if path not in cache:jd,bd=load(path);cache[path]=(jd,bd,Rig(jd))
  jd,bd,RD=cache[path];an=next(a for a in jd['animations'] if a['name']==clip)
  hD=np.array(jd['nodes'][RD.by['mixamorig:Hips']]['translation'])
  ch={};dur=0
  for c in an['channels']:
    sm=an['samplers'][c['sampler']];t=read(jd,bd,sm['input'])[:,0];v=read(jd,bd,sm['output']);ch[(c['target']['node'],c['target']['path'])]=(t,v);dur=max(dur,t[-1])
  times=np.arange(0,dur+1e-6,1/30.)
  if times[-1]<dur-1e-4:times=np.append(times,dur)
  bones=[i for i,n in enumerate(RT.N) if n.get('name') in RD.by and n.get('name','').startswith('mixamorig:')]
  # offsets
  OFF={}
  for i in bones:
    nm=RT.N[i]['name'];di=RD.by[nm];dT=RT.dir(nm);dD=RD.dir(nm)
    A=align(RT.G[i]@np.linalg.inv(RT.G[i])@dT if dT is not None else np.ones(3),dD) if (dT is not None and dD is not None) else np.eye(3)
    OFF[i]=RD.G[di].T@A@RT.G[i]
  outR={i:[] for i in bones};outH=[]
  for x in times:
    GD={}
    def gd(di):
      if di in GD:return GD[di]
      k=(di,'rotation');R=q2m(samp(*ch[k],x,1)) if k in ch else RD.R[di]
      GD[di]=(gd(RD.par[di])@R) if di in RD.par else R;return GD[di]
    GT={}
    def gt(i):
      if i in GT:return GT[i]
      if i in OFF:GT[i]=gd(RD.by[RT.N[i]['name']])@OFF[i]
      else:GT[i]=(gt(RT.par[i])@RT.R[i]) if i in RT.par else RT.R[i]
      return GT[i]
    # parent of hips in target: armature node(s) use rest; donor armature rest may differ -> express via donor world anyway
    for i in bones:
      p=RT.par.get(i);L=(gt(p).T@gt(i)) if p is not None else gt(i)
      outR[i].append(m2q(L))
    k=(RD.by['mixamorig:Hips'],'translation');v=samp(*ch[k],x,0) if k in ch else hD
    outH.append([hT[0],v[1]*hT[1]/hD[1],hT[2]])
  chans=[];samps=[];ti=add(j,b,times.astype(np.float32),'SCALAR',True)
  for i in bones:
    q=np.array(outR[i])
    for n in range(1,len(q)):
      if np.dot(q[n],q[n-1])<0:q[n]=-q[n]
    samps.append({'input':ti,'output':add(j,b,q,'VEC4'),'interpolation':'LINEAR'});chans.append({'sampler':len(samps)-1,'target':{'node':i,'path':'rotation'}})
  samps.append({'input':ti,'output':add(j,b,np.array(outH),'VEC3'),'interpolation':'LINEAR'});chans.append({'sampler':len(samps)-1,'target':{'node':hiT,'path':'translation'}})
  j['animations'].append({'name':new,'channels':chans,'samplers':samps});print('retargeted',new,'from',path.split('/')[-1],f'{dur:.1f}s')
save(tgt,j,b)
