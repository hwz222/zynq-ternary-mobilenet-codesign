"""Affine crop transforms (canonical SimpleBaseline/MPII implementation)."""
import cv2
import numpy as np

from src.config import PIXEL_STD


def get_dir(src_point, rot_rad):
    sn, cs = np.sin(rot_rad), np.cos(rot_rad)
    return [src_point[0] * cs - src_point[1] * sn,
            src_point[0] * sn + src_point[1] * cs]


def get_3rd_point(a, b):
    direct = a - b
    return b + np.array([-direct[1], direct[0]], dtype=np.float32)


def get_affine_transform(center, scale, rot, output_size,
                         shift=np.array([0, 0], dtype=np.float32), inv=False):
    """center: (x,y); scale: scalar or (sx,sy) in MPII units; output_size: (w,h)."""
    if not isinstance(scale, (np.ndarray, list, tuple)):
        scale = np.array([scale, scale], dtype=np.float32)
    scale = np.array(scale, dtype=np.float32)
    center = np.array(center, dtype=np.float32)

    scale_tmp = scale * PIXEL_STD
    src_w = scale_tmp[0]
    dst_w, dst_h = output_size[0], output_size[1]

    rot_rad = np.pi * rot / 180.0
    src_dir = get_dir([0.0, src_w * -0.5], rot_rad)
    dst_dir = np.array([0.0, dst_w * -0.5], dtype=np.float32)

    src = np.zeros((3, 2), dtype=np.float32)
    dst = np.zeros((3, 2), dtype=np.float32)
    src[0, :] = center + scale_tmp * shift
    src[1, :] = center + src_dir + scale_tmp * shift
    dst[0, :] = [dst_w * 0.5, dst_h * 0.5]
    dst[1, :] = np.array([dst_w * 0.5, dst_h * 0.5], dtype=np.float32) + dst_dir

    src[2:, :] = get_3rd_point(src[0, :], src[1, :])
    dst[2:, :] = get_3rd_point(dst[0, :], dst[1, :])

    if inv:
        trans = cv2.getAffineTransform(np.float32(dst), np.float32(src))
    else:
        trans = cv2.getAffineTransform(np.float32(src), np.float32(dst))
    return trans


def affine_transform(pt, t):
    new_pt = np.array([pt[0], pt[1], 1.0], dtype=np.float32).T
    new_pt = np.dot(t, new_pt)
    return new_pt[:2]


def fliplr_joints(joints, joints_vis, width, flip_pairs):
    """Flip joints horizontally; joints in (N,2) pixel coords of width `width`."""
    joints = joints.copy()
    joints_vis = joints_vis.copy()
    joints[:, 0] = width - joints[:, 0] - 1
    for a, b in flip_pairs:
        joints[[a, b], :] = joints[[b, a], :]
        joints_vis[[a, b], :] = joints_vis[[b, a], :]
    return joints, joints_vis
