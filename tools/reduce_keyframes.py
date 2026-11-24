"""Remove redundant animation keyframes from a GLB without visibly changing the motion.

A keyframe is dropped when linear interpolation between its neighbours reproduces it
within a tiny tolerance (rotations: ~0.01 degrees, positions/scales: 0.01 mm-ish).
Tracks that never change collapse to a single key. Mesh, skin and textures are untouched.

Usage: python3 tools/reduce_keyframes.py in.glb out.glb [--eps 1e-4]
Then: python3 tools/reduce_keyframes.py --verify in.glb out.glb   (prints the max error)
"""
import argparse, json, struct
import numpy as np

CT = {5126: np.float32}
NC = {'SCALAR': 1, 'VEC3': 3, 'VEC4': 4}


def load(path):
    b = open(path, 'rb').read()
    L = struct.unpack('<I', b[12:16])[0]
    j = json.loads(b[20:20 + L])
    off = 20 + L
    BL = struct.unpack('<I', b[off:off + 4])[0]
    return j, bytearray(b[off + 8:off + 8 + BL])


def read_acc(j, binb, ai):
    a = j['accessors'][ai]
    v = j['bufferViews'][a['bufferView']]
    n = NC[a['type']]
    assert a['componentType'] == 5126 and v.get('byteStride') in (None, 4 * n)
    o = v.get('byteOffset', 0) + a.get('byteOffset', 0)
    return np.frombuffer(bytes(binb[o:o + a['count'] * 4 * n]), dtype=np.float32).reshape(a['count'], n).copy()


def slerp_or_lerp(path, v0, v1, t):
    if path == 'rotation':
        if np.dot(v0, v1) < 0:
            v1 = -v1
        q = v0 * (1 - t) + v1 * t  # nlerp is what we compare against; three.js slerps, difference is far below eps for close keys
        return q / np.linalg.norm(q)
    return v0 * (1 - t) + v1 * t


def err(path, a, b):
    if path == 'rotation':
        return 1 - abs(float(np.dot(a / np.linalg.norm(a), b / np.linalg.norm(b))))
    return float(np.max(np.abs(a - b)))


def reduce(path, t, v, eps):
    n = len(t)
    if n <= 2:
        return list(range(n))
    tol = eps * eps if path == 'rotation' else eps
    if all(err(path, v[0], v[i]) <= tol for i in range(1, n)):
        return [0]
    keep = [0]
    i = 0
    while i < n - 1:
        # extend the segment from keep[-1] as far as every skipped key stays within tolerance
        j = i + 1
        while j + 1 < n:
            ok = True
            for k in range(i + 1, j + 1):
                u = (t[k] - t[i]) / (t[j + 1] - t[i])
                if err(path, slerp_or_lerp(path, v[i], v[j + 1], u), v[k]) > tol:
                    ok = False
                    break
            if not ok:
                break
            j += 1
        keep.append(j)
        i = j
    return keep


def sample(path, t, v, x):
    if len(t) == 1 or x <= t[0]:
        return v[0]
    if x >= t[-1]:
        return v[-1]
    k = int(np.searchsorted(t, x, side='right')) - 1
    u = (x - t[k]) / (t[k + 1] - t[k])
    return slerp_or_lerp(path, v[k], v[k + 1], u)


def rebuild(j, binb, eps):
    anim_views, anim_accs, tracks = set(), set(), []
    for a in j.get('animations', []):
        for ch in a['channels']:
            s = a['samplers'][ch['sampler']]
            path = ch['target']['path']
            if s.get('interpolation', 'LINEAR') != 'LINEAR' or path not in ('rotation', 'translation', 'scale'):
                continue
            tracks.append((s, path))
    for s, _ in tracks:
        for k in ('input', 'output'):
            anim_accs.add(s[k])
            anim_views.add(j['accessors'][s[k]]['bufferView'])
    # anim buffer views must be used only by animation accessors, otherwise leave the file alone
    for i, a in enumerate(j['accessors']):
        if i not in anim_accs and a.get('bufferView') in anim_views:
            raise SystemExit('buffer view shared with non-animation data; not safe to rewrite')
    new_data, before, after = [], 0, 0
    for s, path in tracks:
        t = read_acc(j, binb, s['input'])[:, 0]
        v = read_acc(j, binb, s['output'])
        keep = reduce(path, t, v, eps)
        before += len(t)
        after += len(keep)
        new_data.append((s, t[keep], v[keep]))
    # write a new binary chunk: all non-animation views copied in order, then fresh animation data
    out = bytearray()
    view_map = {}
    new_views = []
    for vi, v in enumerate(j['bufferViews']):
        if vi in anim_views:
            continue
        o = v.get('byteOffset', 0)
        while len(out) % 4:
            out.append(0)
        nv = dict(v)
        nv['byteOffset'] = len(out)
        out += binb[o:o + v['byteLength']]
        view_map[vi] = len(new_views)
        new_views.append(nv)
    for a in j['accessors']:
        if 'bufferView' in a and a['bufferView'] in view_map:
            a['bufferView'] = view_map[a['bufferView']]
    for im in j.get('images', []):
        if 'bufferView' in im:
            im['bufferView'] = view_map[im['bufferView']]
    # animation inputs are often shared between samplers, so every sampler gets fresh accessors
    # and the old animation accessors are dropped (all other accessor references are remapped)
    acc_map, new_accs = {}, []
    for i, a in enumerate(j['accessors']):
        if i not in anim_accs:
            acc_map[i] = len(new_accs)
            new_accs.append(a)
    for m in j.get('meshes', []):
        for p in m['primitives']:
            p['attributes'] = {k: acc_map[v] for k, v in p['attributes'].items()}
            if 'indices' in p:
                p['indices'] = acc_map[p['indices']]
            for tg in p.get('targets', []):
                for k in tg:
                    tg[k] = acc_map[tg[k]]
    for sk in j.get('skins', []):
        if 'inverseBindMatrices' in sk:
            sk['inverseBindMatrices'] = acc_map[sk['inverseBindMatrices']]
    for a in j.get('animations', []):
        for smp in a['samplers']:
            for k in ('input', 'output'):
                if smp[k] in acc_map:
                    smp[k] = acc_map[smp[k]]
    for s, t, v in new_data:
        for key, arr, typ in (('input', t.reshape(-1, 1), 'SCALAR'), ('output', v, {1: 'SCALAR', 3: 'VEC3', 4: 'VEC4'}[v.shape[1]])):
            while len(out) % 4:
                out.append(0)
            raw = np.ascontiguousarray(arr, dtype=np.float32).tobytes()
            new_views.append({'buffer': 0, 'byteOffset': len(out), 'byteLength': len(raw)})
            out += raw
            acc = {'bufferView': len(new_views) - 1, 'componentType': 5126, 'count': len(arr), 'type': typ}
            if key == 'input':
                acc['min'], acc['max'] = [float(t[0])], [float(t[-1])]
            new_accs.append(acc)
            s[key] = len(new_accs) - 1
    j['accessors'] = new_accs
    j['bufferViews'] = new_views
    while len(out) % 4:
        out.append(0)
    j['buffers'][0]['byteLength'] = len(out)
    return out, before, after


def save(path, j, binb):
    js = json.dumps(j, separators=(',', ':')).encode()
    while len(js) % 4:
        js += b' '
    total = 12 + 8 + len(js) + 8 + len(binb)
    with open(path, 'wb') as f:
        f.write(struct.pack('<III', 0x46546C67, 2, total))
        f.write(struct.pack('<II', len(js), 0x4E4F534A) + js)
        f.write(struct.pack('<II', len(binb), 0x004E4942) + bytes(binb))


def verify(a_path, b_path):
    ja, ba = load(a_path)
    jb, bb = load(b_path)
    worst = {'rotation': 0.0, 'translation': 0.0, 'scale': 0.0}
    for aa, ab in zip(ja['animations'], jb['animations']):
        for ca, cb in zip(aa['channels'], ab['channels']):
            path = ca['target']['path']
            if path not in worst:
                continue
            sa, sb = aa['samplers'][ca['sampler']], ab['samplers'][cb['sampler']]
            ta, va = read_acc(ja, ba, sa['input'])[:, 0], read_acc(ja, ba, sa['output'])
            tb, vb = read_acc(jb, bb, sb['input'])[:, 0], read_acc(jb, bb, sb['output'])
            for x, want in zip(ta, va):
                got = sample(path, tb, vb, x)
                e = np.degrees(2 * np.arccos(min(1.0, abs(float(np.dot(got, want)) / np.linalg.norm(got) / np.linalg.norm(want))))) if path == 'rotation' else float(np.max(np.abs(got - want)))
                worst[path] = max(worst[path], e)
    print('max error: rotation %.4f deg, translation %.6f, scale %.6f' % (worst['rotation'], worst['translation'], worst['scale']))


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--eps', type=float, default=1e-4)
    ap.add_argument('--verify', action='store_true')
    a = ap.parse_args()
    if a.verify:
        verify(a.src, a.dst)
    else:
        j, binb = load(a.src)
        out, before, after = rebuild(j, binb, a.eps)
        save(a.dst, j, out)
        print('%s: keyframes %d -> %d' % (a.dst, before, after))
