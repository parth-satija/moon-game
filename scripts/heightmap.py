#!/usr/bin/env python3
"""moon2height.py: USDZ -> float32 radius map + RGB color map (same lat/lon grid) for Godot.
pip install usd-core numpy scipy pillow
"""
import argparse, json, os, io, re, zipfile
import numpy as np
from pxr import Usd, UsdGeom, UsdShade, Sdf
from scipy import ndimage
from PIL import Image

Image.MAX_IMAGE_PIXELS = None
TWO_PI = 2 * np.pi


# ---------------------------------------------------------------- loading
def primvar_per_vertex(primvar, mesh, npts, ncomp):
    """Return (npts, ncomp) float array, NaN where unknown. Handles vertex & faceVarying."""
    vals = primvar.ComputeFlattened()
    if vals is None:
        return None
    a = np.asarray(vals, dtype=np.float64).reshape(-1, ncomp)
    if len(a) == npts:
        return a
    fvi = np.asarray(mesh.GetFaceVertexIndicesAttr().Get())
    if len(a) == len(fvi):                       # faceVarying -> per vertex (seams: last wins)
        out = np.full((npts, ncomp), np.nan)
        out[fvi] = a
        return out
    if len(a) == 1:                              # constant
        return np.repeat(a, npts, axis=0)
    return None


def find_uv_primvar(mesh):
    api = UsdGeom.PrimvarsAPI(mesh.GetPrim())
    for name in ("st", "st0", "UVMap", "uv", "map1"):
        if api.HasPrimvar(name):
            return api.GetPrimvar(name)
    for p in api.GetPrimvars():
        if p.GetTypeName() in (Sdf.ValueTypeNames.TexCoord2fArray, Sdf.ValueTypeNames.Float2Array):
            return p
    return None


def load_stage(path):
    stage = Usd.Stage.Open(path)
    up = UsdGeom.GetStageUpAxis(stage)
    P, UV, COL = [], [], []
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        pts = mesh.GetPointsAttr().Get()
        if pts is None:
            continue
        p = np.asarray(pts, dtype=np.float64)
        n = len(p)
        m = np.array(UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default()))
        P.append(p @ m[:3, :3] + m[3, :3])                    # USD uses row vectors

        uv = None
        pv = find_uv_primvar(mesh)
        if pv:
            uv = primvar_per_vertex(pv, mesh, n, 2)
        UV.append(uv if uv is not None else np.full((n, 2), np.nan))

        col = None
        dc = mesh.GetDisplayColorPrimvar()
        if dc and dc.HasValue():
            col = primvar_per_vertex(dc, mesh, n, 3)
        COL.append(col if col is not None else np.full((n, 3), np.nan))
    if not P:
        raise SystemExit("No meshes found.")
    return stage, up, np.vstack(P), np.vstack(UV), np.vstack(COL)


def find_texture(stage, usd_path):
    """Return a PIL RGB image of the diffuse/base-color texture, or None."""
    textures = {}                                             # shader prim path -> asset path
    for prim in stage.Traverse():
        if not prim.IsA(UsdShade.Shader):
            continue
        sh = UsdShade.Shader(prim)
        if sh.GetIdAttr().Get() != "UsdUVTexture":
            continue
        f = sh.GetInput("file")
        ap = f.Get() if f else None
        if ap and ap.path:
            textures[str(prim.GetPath())] = ap.path
    if not textures:
        return None

    chosen = None
    for prim in stage.Traverse():                             # prefer the one wired to diffuseColor
        if not prim.IsA(UsdShade.Shader):
            continue
        sh = UsdShade.Shader(prim)
        if sh.GetIdAttr().Get() != "UsdPreviewSurface":
            continue
        try:
            inp = sh.GetInput("diffuseColor")
            src = inp.GetConnectedSource() if inp else None
            if src:
                sp = str(src[0].GetPrim().GetPath())
                if sp in textures:
                    chosen = textures[sp]
                    break
        except Exception:
            pass
    if chosen is None:                                        # filename heuristic
        bad = re.compile(r"normal|nrm|rough|metal|occl|ao|height|disp|bump|spec|emi", re.I)
        good = [t for t in textures.values() if not bad.search(os.path.basename(t))]
        chosen = (good or list(textures.values()))[0]
    print(f"texture: {chosen}")

    base = os.path.basename(chosen)
    if zipfile.is_zipfile(usd_path):
        with zipfile.ZipFile(usd_path) as z:
            names = [n for n in z.namelist() if os.path.basename(n) == base]
            if names:
                return Image.open(io.BytesIO(z.read(names[0]))).convert("RGB")
    p = os.path.join(os.path.dirname(os.path.abspath(usd_path)), chosen)
    if os.path.exists(p):
        return Image.open(p).convert("RGB")
    print("could not locate the texture file")
    return None


# ---------------------------------------------------------------- gridding
def fill_nearest(arr, hole):
    idx = ndimage.distance_transform_edt(hole, return_distances=False, return_indices=True)
    return arr[idx[0], idx[1]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--width", type=int, default=8192)
    ap.add_argument("--color-width", type=int, default=0, help="defaults to --width")
    ap.add_argument("--smooth", type=float, default=0.8)
    ap.add_argument("--out", default="moon")
    a = ap.parse_args()
    W, H = a.width, a.width // 2
    CW = a.color_width or W
    CH = CW // 2

    stage, up, v, uv, col = load_stage(a.input)
    print(f"{len(v):,} vertices, up={up}")
    v -= (v.min(0) + v.max(0)) / 2
    if up == "Z":
        v = v[:, [0, 2, 1]] * np.array([1, 1, -1])
    x, y, z = v.T
    r = np.sqrt(x * x + y * y + z * z)
    lon = np.arctan2(x, z)                                    # matches the GDScript
    lat = np.arcsin(np.clip(y / r, -1, 1))
    del x, y, z, v

    def bins(w, h):
        ix = np.clip(((lon / TWO_PI + 0.5) * w).astype(np.int64), 0, w - 1)
        iy = np.clip(((0.5 - lat / np.pi) * h).astype(np.int64), 0, h - 1)
        return iy * w + ix

    # ---------- height
    flat = bins(W, H)
    sums = np.bincount(flat, weights=r, minlength=W * H)
    cnt = np.bincount(flat, minlength=W * H)
    img = np.full(W * H, np.nan, dtype=np.float32)
    ok = cnt > 0
    img[ok] = (sums[ok] / cnt[ok]).astype(np.float32)
    img = img.reshape(H, W)
    del sums, cnt, flat
    hole = np.isnan(img)
    if hole.any():
        img = fill_nearest(img, hole)
    if a.smooth > 0:
        img = ndimage.gaussian_filter(img, a.smooth, mode=("nearest", "wrap"))
    rmin, rmax, rmean = float(img.min()), float(img.max()), float(img.mean())
    print(f"radius (model units): min {rmin}, max {rmax}, mean {rmean}")
    img.astype("<f4").tofile(f"{a.out}.r32")
    Image.fromarray(((img - rmin) / (rmax - rmin) * 255).astype(np.uint8)).save(f"{a.out}_preview.png")
    del img

    meta = {"width": W, "height": H, "radius_min": rmin, "radius_max": rmax, "mean_radius": rmean}

    # ---------- color
    has_uv = not np.isnan(uv[:, 0]).all()
    has_col = not np.isnan(col[:, 0]).all()
    tex = find_texture(stage, a.input) if has_uv else None
    out = None

    if tex is not None:
        print(f"color source: texture {tex.size[0]}x{tex.size[1]} via UVs -> {CW}x{CH}")
        flat = bins(CW, CH)
        good = ~np.isnan(uv[:, 0])
        grid = np.full((CH * CW, 2), np.nan, dtype=np.float32)
        grid[flat[good]] = uv[good]                           # last write wins: no blending over the UV seam
        grid = grid.reshape(CH, CW, 2)
        del flat, good
        grid = fill_nearest(grid, np.isnan(grid[..., 0]))
        s = max(a.smooth, 0.5)
        ang = grid[..., 0] * TWO_PI                           # smooth u on the circle so the seam survives
        cu = ndimage.gaussian_filter(np.cos(ang).astype(np.float32), s, mode=("nearest", "wrap"))
        su = ndimage.gaussian_filter(np.sin(ang).astype(np.float32), s, mode=("nearest", "wrap"))
        U = (np.arctan2(su, cu) / TWO_PI) % 1.0
        Vv = np.clip(ndimage.gaussian_filter(grid[..., 1], s, mode=("nearest", "wrap")), 0, 1)
        del grid, ang, cu, su

        T = np.asarray(tex)
        th, tw = T.shape[:2]
        out = np.empty((CH, CW, 3), np.uint8)
        for r0 in range(0, CH, 512):                          # chunked to bound memory
            r1 = min(r0 + 512, CH)
            px = U[r0:r1] * tw - 0.5
            py = np.clip((1.0 - Vv[r0:r1]) * th - 0.5, 0, th - 1)
            for c in range(3):
                out[r0:r1, :, c] = np.clip(
                    ndimage.map_coordinates(T[..., c], [py, px], order=1, mode="grid-wrap"), 0, 255)
        meta["color_source"] = "texture"

    elif has_col:
        print("color source: displayColor vertex colors")
        flat = bins(CW, CH)
        good = ~np.isnan(col[:, 0])
        planes = []
        cnt = np.bincount(flat[good], minlength=CW * CH)
        for c in range(3):
            sm = np.bincount(flat[good], weights=col[good, c], minlength=CW * CH)
            ch = np.full(CW * CH, np.nan, dtype=np.float32)
            nz = cnt > 0
            ch[nz] = sm[nz] / cnt[nz]
            planes.append(ch.reshape(CH, CW))
        stack = np.stack(planes, -1)
        stack = fill_nearest(stack, np.isnan(stack[..., 0]))
        if a.smooth > 0:
            stack = np.stack([ndimage.gaussian_filter(stack[..., c], a.smooth, mode=("nearest", "wrap"))
                              for c in range(3)], -1)
        out = (np.clip(stack, 0, 1) * 255).astype(np.uint8)   # displayColor is 0..1
        meta["color_source"] = "displayColor"
    else:
        print("WARNING: no texture or vertex colors found in this file.")

    if out is not None:
        out.tofile(f"{a.out}.rgb")                            # raw RGB8, CW*CH*3 bytes
        Image.fromarray(out).save(f"{a.out}_color_preview.png")
        meta["color_width"], meta["color_height"] = CW, CH

    json.dump(meta, open(f"{a.out}.json", "w"), indent=2)


if __name__ == "__main__":
    main()