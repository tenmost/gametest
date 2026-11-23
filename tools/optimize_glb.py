"""Shrink a skinned Meshy/Mixamo GLB for the browser game.

- simplifies the mesh by vertex clustering (positions shared per spatial cell so no
  cracks at UV seams; UVs averaged per cell+UV-chart; skin weights averaged)
- resizes textures to --tex px JPEG
- keeps only the animations listed in --keep
Usage: python3 optimize_glb.py in.glb out.glb --cell 0.009 --tex 1024 --keep Idle_15,Victory_Cheer,Dead
"""
import argparse, io, json, struct
import numpy as np
from PIL import Image

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def load(path):
    b = open(path, 'rb').read()
    L = struct.unpack('<I', b[12:16])[0]
    j = json.loads(b[20:20 + L])
    off = 20 + L
    BL = struct.unpack('<I', b[off:off + 4])[0]
    return j, b[off + 8:off + 8 + BL]


def view_bytes(j, binb, vi):
    v = j['bufferViews'][vi]
    o = v.get('byteOffset', 0)
    return binb[o:o + v['byteLength']]


def acc_array(j, binb, ai):
    a = j['accessors'][ai]
    v = j['bufferViews'][a['bufferView']]
    dt = CT[a['componentType']]
    n = NC[a['type']]
    o = v.get('byteOffset', 0) + a.get('byteOffset', 0)
    stride = v.get('byteStride')
    isz = np.dtype(dt).itemsize * n
    if stride and stride != isz:
        raw = np.frombuffer(binb, np.uint8, count=stride * a['count'], offset=o).reshape(a['count'], stride)[:, :isz]
        arr = np.frombuffer(raw.tobytes(), dt).reshape(a['count'], n)
    else:
        arr = np.frombuffer(binb, dt, count=a['count'] * n, offset=o).reshape(a['count'], n)
    if a.get('normalized') and dt != np.float32:
        arr = arr.astype(np.float32) / np.iinfo(dt).max
    return arr


def components(nv, tris):
    parent = np.arange(nv)

    def find(x):
        root = x
        while parent[root] != root:
            root = parent[root]
        while parent[x] != root:
            parent[x], x = root, parent[x]
        return root
    # vectorised-ish union via repeated pointer jumping
    e = np.concatenate([tris[:, [0, 1]], tris[:, [1, 2]]])
    for _ in range(64):
        a, b = parent[e[:, 0]], parent[e[:, 1]]
        lo, hi = np.minimum(a, b), np.maximum(a, b)
        changed = lo != hi
        if not changed.any():
            break
        np.minimum.at(parent, hi[changed], lo[changed])
        for _ in range(8):
            parent = parent[parent]
    for _ in range(32):
        parent = parent[parent]
    return parent


def simplify(P, N, UV, J, W, tris, cell, fine_mask=None, fine_cell=None):
    nv = len(P)
    chart = components(nv, tris)
    mn = P.min(0)
    if fine_mask is None:
        fine_mask = np.zeros(nv, bool)
    csz = np.where(fine_mask, fine_cell or cell, cell)[:, None]
    c = np.floor((P - mn) / csz).astype(np.int64)
    ckey = (c[:, 0] * 73856093) ^ (c[:, 1] * 19349663) ^ (c[:, 2] * 83492791) ^ (fine_mask.astype(np.int64) << 60)
    _, cell_id = np.unique(ckey, return_inverse=True)
    # shared position per spatial cell
    ncell = cell_id.max() + 1
    cnt = np.bincount(cell_id, minlength=ncell).astype(np.float64)
    cpos = np.stack([np.bincount(cell_id, P[:, k], ncell) for k in range(3)], 1) / cnt[:, None]
    # vertex per (cell, chart)
    vkey = cell_id.astype(np.int64) * (chart.max() + 1) + chart
    uk, vid = np.unique(vkey, return_inverse=True)
    m = len(uk)
    vc = np.bincount(vid, minlength=m).astype(np.float64)
    newP = cpos[uk // (chart.max() + 1)].astype(np.float32)
    newUV = (np.stack([np.bincount(vid, UV[:, k], m) for k in range(2)], 1) / vc[:, None]).astype(np.float32)
    nn = np.stack([np.bincount(vid, N[:, k], m) for k in range(3)], 1)
    newN = (nn / np.maximum(np.linalg.norm(nn, axis=1, keepdims=True), 1e-9)).astype(np.float32)
    # skin: accumulate dense joint weights per new vertex, keep top 4
    nj = int(J.max()) + 1
    dense = np.zeros((m, nj), np.float32)
    for k in range(4):
        np.add.at(dense, (vid, J[:, k].astype(np.int64)), W[:, k])
    top = np.argsort(-dense, axis=1)[:, :4]
    tw = np.take_along_axis(dense, top, 1)
    tw /= np.maximum(tw.sum(1, keepdims=True), 1e-9)
    newJ = top.astype(np.uint8 if nj < 256 else np.uint16)
    newW = tw.astype(np.float32)
    t = vid[tris]
    ok = (t[:, 0] != t[:, 1]) & (t[:, 1] != t[:, 2]) & (t[:, 0] != t[:, 2])
    t = t[ok]
    # drop exact duplicate triangles
    s = np.sort(t, 1)
    _, first = np.unique(s, axis=0, return_index=True)
    t = t[np.sort(first)]
    return newP, newN, newUV, newJ, newW, t.astype(np.uint32)


class Writer:
    def __init__(self):
        self.buf = bytearray(); self.views = []; self.accs = []

    def view(self, data, target=None):
        while len(self.buf) % 4: self.buf.append(0)
        v = {'buffer': 0, 'byteOffset': len(self.buf), 'byteLength': len(data)}
        if target: v['target'] = target
        self.buf += data; self.views.append(v); return len(self.views) - 1

    def acc(self, arr, typ, target=None, minmax=False):
        arr = np.ascontiguousarray(arr)
        ct = {np.dtype(np.float32): 5126, np.dtype(np.uint32): 5125, np.dtype(np.uint16): 5123, np.dtype(np.uint8): 5121}[arr.dtype]
        a = {'bufferView': self.view(arr.tobytes(), target), 'componentType': ct, 'count': int(arr.shape[0]), 'type': typ}
        if minmax:
            a['min'] = arr.min(0).tolist(); a['max'] = arr.max(0).tolist()
        self.accs.append(a); return len(self.accs) - 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inp'); ap.add_argument('out')
    ap.add_argument('--cell', type=float, default=0.009)
    ap.add_argument('--tex', type=int, default=1024)
    ap.add_argument('--keep', default='')
    ap.add_argument('--merge', default='', help='another GLB with the same skeleton whose animations are added')
    ap.add_argument('--no-simplify', action='store_true')
    ap.add_argument('--fine-cell', type=float, default=0.0, help='smaller cell for vertices driven by hand/finger bones')
    a = ap.parse_args()
    j, binb = load(a.inp)
    keep = [k for k in a.keep.split(',') if k]
    w = Writer()
    remap = {}

    def copy_acc(ai, typ_override=None):
        if ai in remap: return remap[ai]
        arr = acc_array(j, binb, ai)
        src = j['accessors'][ai]
        if arr.dtype not in (np.float32, np.uint32, np.uint16, np.uint8):
            arr = arr.astype(np.float32)
        na = w.acc(arr, src['type'], minmax='min' in src)
        remap[ai] = na; return na

    prim = j['meshes'][0]['primitives'][0]
    at = prim['attributes']
    P = acc_array(j, binb, at['POSITION']).astype(np.float32)
    N = acc_array(j, binb, at['NORMAL']).astype(np.float32)
    UV = acc_array(j, binb, at['TEXCOORD_0']).astype(np.float32)
    J = acc_array(j, binb, at['JOINTS_0'])
    W = acc_array(j, binb, at['WEIGHTS_0']).astype(np.float32)
    T = acc_array(j, binb, prim['indices']).reshape(-1, 3).astype(np.int64)
    fine = None
    if a.fine_cell > 0 and j.get('skins'):
        names = [j['nodes'][n].get('name', '') for n in j['skins'][0]['joints']]
        hand = np.array(['Hand' in n for n in names])
        dom = J[np.arange(len(J)), np.argmax(W, 1)].astype(int)
        fine = hand[dom]
        print('fine (hand) vertices:', int(fine.sum()))
    if a.no_simplify:
        nP, nN, nUV, nJ, nW, nT = P, N, UV, J.astype(np.uint8 if J.max() < 256 else np.uint16), W, T.astype(np.uint32)
    else:
        nP, nN, nUV, nJ, nW, nT = simplify(P, N, UV, J, W, T, a.cell, fine, a.fine_cell)
    print(f'mesh: {len(P)} verts / {len(T)} tris  ->  {len(nP)} verts / {len(nT)} tris')
    idx = nT.reshape(-1).astype(np.uint16 if len(nP) < 65535 else np.uint32)
    prim2 = {'attributes': {'POSITION': w.acc(nP, 'VEC3', 34962, True), 'NORMAL': w.acc(nN, 'VEC3', 34962),
             'TEXCOORD_0': w.acc(nUV, 'VEC2', 34962), 'JOINTS_0': w.acc(nJ, 'VEC4', 34962), 'WEIGHTS_0': w.acc(nW, 'VEC4', 34962)},
             'indices': w.acc(idx, 'SCALAR', 34963), 'material': prim.get('material', 0), 'mode': 4}
    j['meshes'][0]['primitives'] = [prim2]
    for s in j.get('skins', []):
        if 'inverseBindMatrices' in s: s['inverseBindMatrices'] = copy_acc(s['inverseBindMatrices'])
    anims = []
    for an in j.get('animations', []):
        if keep and an['name'] not in keep: continue
        for smp in an['samplers']:
            smp['input'] = copy_acc(smp['input']); smp['output'] = copy_acc(smp['output'])
        anims.append(an)
    if a.merge:
        j2, b2 = load(a.merge)
        byname = {n.get('name'): i for i, n in enumerate(j['nodes'])}
        for an in j2.get('animations', []):
            if keep and an['name'] not in keep: continue
            chans, samps = [], []
            for ch in an['channels']:
                nm = j2['nodes'][ch['target']['node']].get('name')
                if nm not in byname: continue
                smp = an['samplers'][ch['sampler']]
                arr_in = acc_array(j2, b2, smp['input']); arr_out = acc_array(j2, b2, smp['output'])
                src_in = j2['accessors'][smp['input']]; src_out = j2['accessors'][smp['output']]
                ni = w.acc(arr_in.astype(np.float32), src_in['type'], minmax=True); no = w.acc(arr_out.astype(np.float32), src_out['type'])
                samps.append({'input': ni, 'output': no, 'interpolation': smp.get('interpolation', 'LINEAR')})
                chans.append({'sampler': len(samps) - 1, 'target': {'node': byname[nm], 'path': ch['target']['path']}})
            anims.append({'name': an['name'], 'channels': chans, 'samplers': samps})
    j['animations'] = anims
    for im in j.get('images', []):
        img = Image.open(io.BytesIO(view_bytes(j, binb, im['bufferView'])))
        if img.width > a.tex: img = img.resize((a.tex, a.tex), Image.LANCZOS)
        out = io.BytesIO(); img.convert('RGB').save(out, 'JPEG', quality=86, optimize=True)
        im['bufferView'] = w.view(out.getvalue()); im['mimeType'] = 'image/jpeg'
    j['bufferViews'] = w.views; j['accessors'] = w.accs
    while len(w.buf) % 4: w.buf.append(0)
    j['buffers'] = [{'byteLength': len(w.buf)}]
    js = json.dumps(j, separators=(',', ':')).encode()
    while len(js) % 4: js += b' '
    total = 12 + 8 + len(js) + 8 + len(w.buf)
    with open(a.out, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, total))
        f.write(struct.pack('<II', len(js), 0x4E4F534A)); f.write(js)
        f.write(struct.pack('<II', len(w.buf), 0x004E4942)); f.write(w.buf)
    print('animations kept:', [x['name'] for x in anims])
    print(f'size: {total/1e6:.2f} MB')


if __name__ == '__main__':
    main()
