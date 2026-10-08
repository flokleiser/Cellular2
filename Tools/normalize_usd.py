import argparse
import shutil
import sys
from pathlib import Path

import numpy as np
from pxr import Usd, UsdGeom


def mesh_points(stage):
    chunks = []
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        points = np.array(UsdGeom.Mesh(prim).GetPointsAttr().Get(), dtype=float)
        matrix = np.array(UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default()))
        homogeneous = np.c_[points, np.ones(len(points))]
        chunks.append((homogeneous @ matrix)[:, :3])
    return np.vstack(chunks)


def normalize(source, destination, double_sided):
    shutil.copy(source, destination)
    stage = Usd.Stage.Open(str(destination))
    root = stage.GetDefaultPrim()
    if not root:
        raise RuntimeError(f"{source.name} has no default prim")
    if UsdGeom.GetStageUpAxis(stage) != UsdGeom.Tokens.z:
        raise RuntimeError(f"{source.name} is not Z-up")
    points = mesh_points(stage)
    center = (points.min(axis=0) + points.max(axis=0)) / 2
    xformable = UsdGeom.Xformable(root)
    existing = list(xformable.GetOrderedXformOps())
    rotate = xformable.AddRotateXOp(opSuffix="normalize")
    rotate.Set(-90.0)
    translate = xformable.AddTranslateOp(opSuffix="normalize")
    translate.Set(tuple(float(-c) for c in center))
    xformable.SetXformOpOrder([rotate, translate] + existing)
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.y)
    if double_sided:
        for prim in stage.Traverse():
            if prim.IsA(UsdGeom.Mesh):
                UsdGeom.Mesh(prim).GetDoubleSidedAttr().Set(True)
    stage.GetRootLayer().Save()
    check = Usd.Stage.Open(str(destination))
    verified = mesh_points(check)
    extent = verified.max(axis=0) - verified.min(axis=0)
    offset = (verified.max(axis=0) + verified.min(axis=0)) / 2
    print(f"{source.name}: up={UsdGeom.GetStageUpAxis(check)} extent {np.round(extent, 3)} center offset {np.round(offset, 4)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for source in args.sources:
        double_sided = "membrane" in source.stem.lower()
        normalize(source, args.out / source.name, double_sided)
    return 0


if __name__ == "__main__":
    sys.exit(main())
