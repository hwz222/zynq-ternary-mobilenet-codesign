"""CenterNet loss and decoding on the 16-channel 64x64 output."""
import torch
import torch.nn.functional as F

from src import config as C


def focal_loss(logits, gt):
    """CenterNet's penalty-reduced focal loss (alpha 2, beta 4), mean over positives."""
    p = torch.sigmoid(logits.float()).clamp(1e-4, 1 - 1e-4)
    pos = gt.eq(1).float()
    neg = 1 - pos
    pos_l = torch.log(p) * (1 - p) ** 2 * pos
    neg_l = torch.log(1 - p) * p ** 2 * (1 - gt) ** 4 * neg
    n = pos.sum()
    return -(pos_l.sum() + neg_l.sum()) / n.clamp(min=1)


def gather(feat, ind):
    """feat (N,2,H,W), ind (N,K) flat indices -> (N,K,2)."""
    n, c = feat.shape[:2]
    f = feat.reshape(n, c, -1).permute(0, 2, 1)
    return f.gather(1, ind.unsqueeze(2).expand(-1, -1, c))


def loss_fn(out, hm, wh, off, ind, msk, w_wh=1.0, w_off=1.0):
    l_hm = focal_loss(out[:, :C.NUM_CLASSES], hm)
    m = msk.unsqueeze(2)
    n = m.sum().clamp(min=1)
    l_wh = (F.l1_loss(gather(out[:, list(C.CH_WH)], ind) * m, wh * m, reduction="sum")) / n
    l_off = (F.l1_loss(gather(out[:, list(C.CH_OFF)], ind) * m, off * m, reduction="sum")) / n
    return l_hm + w_wh * l_wh + w_off * l_off, (l_hm.item(), l_wh.item(), l_off.item())


@torch.no_grad()
def decode(out, k=100):
    """-> (N,k,6): x0, y0, x1, y1 in INPUT pixels, score, class."""
    hm = torch.sigmoid(out[:, :C.NUM_CLASSES].float())
    peak = F.max_pool2d(hm, 3, 1, 1)
    hm = hm * (peak == hm).float()
    n, c, h, w = hm.shape
    sc, idx = hm.reshape(n, -1).topk(k)
    cls = idx // (h * w)
    pix = idx % (h * w)
    ys, xs = (pix // w).float(), (pix % w).float()
    wh = gather(out[:, list(C.CH_WH)].float(), pix) * C.WH_UNIT
    of = gather(out[:, list(C.CH_OFF)].float(), pix)
    cx = (xs + of[..., 0]) * C.STRIDE
    cy = (ys + of[..., 1]) * C.STRIDE
    bw, bh = wh[..., 0].clamp(min=0), wh[..., 1].clamp(min=0)
    return torch.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2, sc, cls.float()], 2)
