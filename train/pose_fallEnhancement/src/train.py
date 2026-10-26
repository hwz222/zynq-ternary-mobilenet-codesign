"""Reusable training loop for FP32 / INT8 / TWN configs (one code path)."""
import argparse
import json
import os
import time

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader

from src.config import EXP_DIR, INPUT_SIZE
from src.dataset import MPIIDataset
from src.evaluate import evaluate


class JointsMSELoss(nn.Module):
    """Canonical SimpleBaseline heatmap MSE. Two optional, default-off extensions for the
    weak-joint fine-tune (both preserve the original numerics when unset):
      joint_w : (K,) per-joint loss weights (e.g. boost wrists/knees/ankles)
      topk    : OHKM (CPN/MSPN): per sample, average only the top-k hardest joints' losses."""

    def __init__(self, use_target_weight=True, joint_w=None, topk=None):
        super().__init__()
        self.criterion = nn.MSELoss(reduction="mean")
        self.use_target_weight = use_target_weight
        self.topk = topk
        self.register_buffer("joint_w",
                             None if joint_w is None else torch.as_tensor(joint_w, dtype=torch.float32),
                             persistent=False)

    def forward(self, output, target, target_weight):
        N, K = output.shape[0], output.shape[1]
        if self.topk is None and self.joint_w is None:
            ho = output.reshape(N, K, -1).split(1, 1)
            ht = target.reshape(N, K, -1).split(1, 1)
            loss = 0.0
            for k in range(K):
                o = ho[k].squeeze(1)
                t = ht[k].squeeze(1)
                if self.use_target_weight:
                    w = target_weight[:, k]
                    loss += 0.5 * self.criterion(o * w, t * w)
                else:
                    loss += 0.5 * self.criterion(o, t)
            return loss / K
        # extended path: per-(sample,joint) losses, then joint weights and/or OHKM top-k
        o = output.reshape(N, K, -1)
        t = target.reshape(N, K, -1)
        if self.use_target_weight:
            w = target_weight.reshape(N, K, 1)
            o = o * w
            t = t * w
        lj = 0.5 * ((o - t) ** 2).mean(dim=2)              # (N, K)
        if self.joint_w is not None:
            lj = lj * self.joint_w.reshape(1, K)
        if self.topk is not None and self.topk < K:
            lj, _ = torch.topk(lj, self.topk, dim=1)       # hardest k joints per sample
        return lj.mean()


def build_loaders(batch, workers, sample_weights=None):
    """persistent_workers is deliberately OFF: with it on, the train loader's AND the val
    loader's workers both stay alive for the loader's lifetime (~2.2 GB each on this box)
    and accumulate across configs -- that is what ballooned the pagefile to 87 GB and left
    34 orphaned python processes. Off => workers spawn per iteration and exit after it, so
    train and val workers never coexist. Costs ~1-2 s/epoch to respawn."""
    train_ds = MPIIDataset("train")
    val_ds = MPIIDataset("valid")
    sampler = None
    if sample_weights is not None:
        # hard-example oversampling: weights indexed by dataset idx; epoch length unchanged
        assert len(sample_weights) == len(train_ds)
        sampler = torch.utils.data.WeightedRandomSampler(
            torch.as_tensor(sample_weights, dtype=torch.double),
            num_samples=len(train_ds), replacement=True)
    train_loader = DataLoader(train_ds, batch_size=batch,
                              shuffle=(sampler is None), sampler=sampler,
                              num_workers=workers, pin_memory=True, drop_last=True,
                              persistent_workers=False)
    val_loader = DataLoader(val_ds, batch_size=batch, shuffle=False,
                            num_workers=workers, pin_memory=True,
                            persistent_workers=False)
    return train_loader, val_loader


def train(model, exp_id, epochs=140, lr=1e-3, lr_steps=(90, 120), gamma=0.1,
          batch=64, workers=6, device="cuda", init_weights=None,
          eval_every=5, eval_tail=20, resume=True, log=print):
    torch.backends.cudnn.benchmark = True
    out_dir = os.path.join(EXP_DIR, exp_id)
    os.makedirs(out_dir, exist_ok=True)
    metrics_path = os.path.join(out_dir, "metrics.jsonl")
    last_path = os.path.join(out_dir, "last.pth")
    best_path = os.path.join(out_dir, "best.pth")

    # IMPORTANT Brevitas/device ordering (verified empirically): a load_state_dict AFTER
    # .to(device) resets Brevitas' lazily-built quant buffers back to CPU. So we relay on
    # CPU *before* the move, and follow any later load with another .to(device).
    #
    # 1) Relay weights on CPU (quant buffers don't exist yet -> only conv/bn keys match).
    if init_weights and os.path.isfile(init_weights):
        sd = torch.load(init_weights, map_location="cpu")
        sd = sd.get("model", sd)
        own = model.state_dict()
        transfer = {k: v for k, v in sd.items() if k in own and own[k].shape == v.shape}
        model.load_state_dict(transfer, strict=False)
        log(f"[relay] loaded {len(transfer)}/{len(own)} tensors from {init_weights}")

    # 2) Materialize lazy (Brevitas) submodules with one CPU forward, then move to device.
    model.eval()
    with torch.no_grad():
        model(torch.zeros(1, 3, INPUT_SIZE[1], INPUT_SIZE[0]))
    model = model.to(device)
    model.train()

    criterion = JointsMSELoss().to(device)
    optimizer = torch.optim.Adam(model.parameters(), lr=lr)
    scheduler = torch.optim.lr_scheduler.MultiStepLR(optimizer, list(lr_steps), gamma)

    start_epoch, best_pckh = 0, -1.0
    if resume and os.path.isfile(last_path):
        ck = torch.load(last_path, map_location=device)
        model.load_state_dict(ck["model"])
        optimizer.load_state_dict(ck["optimizer"])
        scheduler.load_state_dict(ck["scheduler"])
        model.to(device)  # load_state_dict resets Brevitas buffers to CPU -> re-move
        start_epoch = ck["epoch"] + 1
        best_pckh = ck.get("best_pckh", -1.0)
        log(f"[resume] from epoch {start_epoch}, best PCKh so far {best_pckh:.3f}")

    train_loader, val_loader = build_loaders(batch, workers)
    log(f"[data] train batches={len(train_loader)} val batches={len(val_loader)}")

    for epoch in range(start_epoch, epochs):
        model.train()
        t0 = time.time()
        running = 0.0
        for i, (inp, target, tw, _) in enumerate(train_loader):
            inp = inp.to(device, non_blocking=True)
            target = target.to(device, non_blocking=True)
            tw = tw.to(device, non_blocking=True)
            out = model(inp)
            loss = criterion(out, target, tw)
            optimizer.zero_grad()
            loss.backward()
            optimizer.step()
            running += loss.item()
        scheduler.step()
        avg_loss = running / len(train_loader)
        dt = time.time() - t0

        do_eval = ((epoch + 1) % eval_every == 0) or (epoch >= epochs - eval_tail) or (epoch == epochs - 1)
        pckh = None
        if do_eval:
            res = evaluate(model, val_loader, device)
            pckh = res["PCKh"]
            if pckh > best_pckh:
                best_pckh = pckh
                torch.save({"model": model.state_dict(), "epoch": epoch,
                            "pckh": pckh, "exp_id": exp_id}, best_path)
            log(f"epoch {epoch:3d} | loss {avg_loss:.5f} | lr {optimizer.param_groups[0]['lr']:.2e} "
                f"| {dt:.1f}s | PCKh {pckh:.3f} | best {best_pckh:.3f}")
            with open(metrics_path, "a") as f:
                f.write(json.dumps({"epoch": epoch, "loss": avg_loss, "pckh": pckh,
                                    "best": best_pckh, "groups": res["groups"]}) + "\n")
        else:
            log(f"epoch {epoch:3d} | loss {avg_loss:.5f} | lr {optimizer.param_groups[0]['lr']:.2e} | {dt:.1f}s")
            with open(metrics_path, "a") as f:
                f.write(json.dumps({"epoch": epoch, "loss": avg_loss}) + "\n")

        torch.save({"model": model.state_dict(), "optimizer": optimizer.state_dict(),
                    "scheduler": scheduler.state_dict(), "epoch": epoch,
                    "best_pckh": best_pckh, "exp_id": exp_id}, last_path)

    log(f"[done] {exp_id} best PCKh = {best_pckh:.3f}")
    return best_pckh


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exp-id", default="fp32_baseline")
    ap.add_argument("--epochs", type=int, default=140)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--no-pretrained", action="store_true")
    args = ap.parse_args()

    from src.model import PoseResNet18, load_imagenet_backbone
    model = PoseResNet18()
    if not args.no_pretrained:
        n, _ = load_imagenet_backbone(model)
        print(f"[init] loaded {n} ImageNet backbone tensors")
    train(model, exp_id=args.exp_id, epochs=args.epochs, lr=args.lr,
          batch=args.batch, workers=args.workers)


if __name__ == "__main__":
    main()
