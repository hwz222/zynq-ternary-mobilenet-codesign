"""Heatmap target generation and decoding (canonical SimpleBaseline)."""
import numpy as np

from src.config import HEATMAP_SIZE, INPUT_SIZE, SIGMA


def generate_target(joints, joints_vis):
    """joints: (K,2) in INPUT_SIZE pixel coords; joints_vis: (K,1) in {0,1}.

    Returns target (K, Hh, Hw) gaussian heatmaps and target_weight (K,1).
    """
    num_joints = joints.shape[0]
    hm_w, hm_h = HEATMAP_SIZE
    img_w, img_h = INPUT_SIZE
    feat_stride = np.array([img_w / hm_w, img_h / hm_h], dtype=np.float32)

    target_weight = np.ones((num_joints, 1), dtype=np.float32)
    target_weight[:, 0] = joints_vis[:, 0]
    target = np.zeros((num_joints, hm_h, hm_w), dtype=np.float32)

    tmp_size = SIGMA * 3
    for j in range(num_joints):
        mu_x = int(joints[j][0] / feat_stride[0] + 0.5)
        mu_y = int(joints[j][1] / feat_stride[1] + 0.5)
        ul = [int(mu_x - tmp_size), int(mu_y - tmp_size)]
        br = [int(mu_x + tmp_size + 1), int(mu_y + tmp_size + 1)]
        if ul[0] >= hm_w or ul[1] >= hm_h or br[0] < 0 or br[1] < 0:
            target_weight[j] = 0
            continue
        size = 2 * tmp_size + 1
        x = np.arange(0, size, 1, np.float32)
        y = x[:, np.newaxis]
        x0 = y0 = size // 2
        g = np.exp(-((x - x0) ** 2 + (y - y0) ** 2) / (2 * SIGMA ** 2))
        g_x = (max(0, -ul[0]), min(br[0], hm_w) - ul[0])
        g_y = (max(0, -ul[1]), min(br[1], hm_h) - ul[1])
        img_x = (max(0, ul[0]), min(br[0], hm_w))
        img_y = (max(0, ul[1]), min(br[1], hm_h))
        if target_weight[j] > 0.5:
            target[j][img_y[0]:img_y[1], img_x[0]:img_x[1]] = \
                g[g_y[0]:g_y[1], g_x[0]:g_x[1]]
    return target, target_weight


def get_max_preds(batch_heatmaps):
    """batch_heatmaps: np.ndarray (N,K,H,W). Returns preds (N,K,2) in heatmap
    coords and maxvals (N,K,1)."""
    assert batch_heatmaps.ndim == 4
    N, K, _, W = batch_heatmaps.shape
    reshaped = batch_heatmaps.reshape((N, K, -1))
    idx = np.argmax(reshaped, 2).reshape((N, K, 1))
    maxvals = np.max(reshaped, 2).reshape((N, K, 1))
    preds = np.tile(idx, (1, 1, 2)).astype(np.float32)
    preds[:, :, 0] = preds[:, :, 0] % W            # x
    preds[:, :, 1] = np.floor(preds[:, :, 1] / W)  # y
    pred_mask = np.tile(maxvals > 0.0, (1, 1, 2)).astype(np.float32)
    preds *= pred_mask
    return preds, maxvals


def decode_with_offset(batch_heatmaps):
    """get_max_preds + quarter-pixel offset toward the second-highest neighbour
    (standard post-processing, ~1-2 PCKh)."""
    coords, maxvals = get_max_preds(batch_heatmaps)
    N, K, H, W = batch_heatmaps.shape
    for n in range(N):
        for k in range(K):
            hm = batch_heatmaps[n, k]
            px, py = int(coords[n, k, 0]), int(coords[n, k, 1])
            if 1 < px < W - 1 and 1 < py < H - 1:
                dx = hm[py, px + 1] - hm[py, px - 1]
                dy = hm[py + 1, px] - hm[py - 1, px]
                coords[n, k, 0] += np.sign(dx) * 0.25
                coords[n, k, 1] += np.sign(dy) * 0.25
    return coords, maxvals
