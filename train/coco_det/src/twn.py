"""TWN ternary weight quantizer (Brevitas-native) + Discipline-B verification.

TWNWeightPerTensor mirrors Brevitas' Int8WeightPerTensorFloat but:
  - bit_width = 2 with NarrowIntQuant  -> narrow signed 2-bit int = {-1, 0, +1}
  - scale = mean(|W|) per-tensor (StatsOp.AVE) == TWN-style data-dependent alpha,
    recomputed from the latent float weights every forward pass.

This is a faithful "ternary weights {-1,0,+1} with a per-tensor scaling factor" (TWN).
The zero-band is |W| < 0.5*scale = 0.5*mean(|W|) (classic TWN uses 0.7*mean|W|; we
record this difference honestly). Discipline B is enforced by verify_ternary().
"""
import torch
from brevitas.inject.enum import RestrictValueType, ScalingPerOutputType, StatsOp
from brevitas.quant.base import MaxStatsScaling, NarrowIntQuant
from brevitas.quant.solver.weight import WeightQuantSolver


class TWNWeightPerTensor(NarrowIntQuant, MaxStatsScaling, WeightQuantSolver):
    """Ternary {-1,0,+1} per-tensor weight quantizer, scale = mean(|W|)."""
    scaling_stats_op = StatsOp.AVE                       # mean(|W|)  (overrides MAX)
    scaling_per_output_type = ScalingPerOutputType.TENSOR
    restrict_scaling_type = RestrictValueType.FP
    bit_width = 2


class TWNWeightPerChannel(NarrowIntQuant, MaxStatsScaling, WeightQuantSolver):
    """Ternary {-1,0,+1} weight quantizer with one alpha PER OUTPUT CHANNEL.

    Same construction as Brevitas' own Int8WeightPerChannelFloat (NarrowIntQuant +
    MaxStatsScaling + PerChannelFloatScaling8bit + WeightQuantSolver), but with
    bit_width=2 and StatsOp.AVE. WeightQuantSolver derives the stats view shape from
    scaling_per_output_type, so no extra view/permute config is needed.

    Why this exists: a per-TENSOR alpha cannot describe a depthwise conv, whose every
    output channel owns only k*k = 9 weights. Measured on this project, ternarizing the
    depthwise convs per-tensor costs 1.89 PCKh while buying only 0.9% of the model's MACs
    (dsc_pwdw vs dsc_pw). A per-output-channel alpha is FREE on the target FPGA: the
    requantizer is already per-output-channel (A_c = gamma_c/sqrt(var_c+eps) *
    (s_w * s_in) / s_out), so s_w -> s_w,c simply folds into the existing M0_c.
    """
    scaling_stats_op = StatsOp.AVE
    scaling_per_output_type = ScalingPerOutputType.CHANNEL
    restrict_scaling_type = RestrictValueType.FP
    bit_width = 2


@torch.no_grad()
def ternary_ints(qmodule):
    """Integer (pre-scale) weights of a Brevitas quant conv/linear, plus dequant & scale.

    `scale` is a 0-dim tensor for per-tensor quantizers and (OC,1,1,1) for per-channel
    ones; the division broadcasts correctly in both cases.
    """
    qw = qmodule.quant_weight()
    scale = qw.scale
    deq = qw.value
    ints = torch.round(deq / scale)
    return ints, deq, scale


@torch.no_grad()
def verify_ternary(qmodule, name="", atol=1e-4):
    """Discipline B: weights truly ternary {-1,0,+1} (pre-scale) AND zeros present.

    Returns a dict; ['ok'] is True only if every integer is in {-1,0,1}, at least one
    zero exists, and dequant == int*scale within atol.

    Per-channel quantizers report `n_scales` > 1 plus the spread of the per-channel zero
    fraction. `ok` deliberately only requires a zero to exist in the TENSOR: with one
    alpha per output channel, a channel whose 9 weights all clear the threshold has no
    zeros, and that is legitimate (observed on depthwise layers), not a quantizer failure.
    """
    ints, deq, scale = ternary_ints(qmodule)
    uniq = sorted(int(round(u)) for u in torch.unique(ints).tolist())
    in_set = set(uniq).issubset({-1, 0, 1})
    n = ints.numel()
    n_zero = int((ints == 0).sum())
    n_pos = int((ints == 1).sum())
    n_neg = int((ints == -1).sum())
    recon_err = float((deq - ints * scale).abs().max())
    ok = bool(in_set and n_zero > 0 and (n_zero + n_pos + n_neg == n) and recon_err < atol)

    n_scales = int(scale.numel())
    out = {
        "name": name, "ok": ok, "unique_ints": uniq, "n": n,
        "frac_zero": n_zero / n, "frac_pos": n_pos / n, "frac_neg": n_neg / n,
        "scale": float(scale.reshape(-1)[0]), "n_scales": n_scales,
        "recon_err": recon_err,
    }
    if n_scales > 1:
        # The scale's only non-singleton dim IS the quantized output-channel axis, whether
        # the weight is (OC,IC,k,k) or a transpose's (IC,OC,k,k) -- don't assume dim 0.
        ch_dim = next(i for i, s in enumerate(scale.shape) if s > 1)
        zf = (ints == 0).float().transpose(0, ch_dim).reshape(n_scales, -1).mean(1)
        out.update({"per_ch_zero_min": float(zf.min()), "per_ch_zero_max": float(zf.max()),
                    "scale_min": float(scale.min()), "scale_max": float(scale.max())})
    return out
