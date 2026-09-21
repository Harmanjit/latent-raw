#!/usr/bin/env python3
"""
Convert BiRefNet (dichotomous image segmentation: one-shot subject masks)
from Hugging Face into a Core ML package for Latent's MLKit, and write the
manifest the model registry reads.

    source ~/latent-ml/bin/activate
    python scripts/convert_birefnet.py --variant lite            # the bundled one
    python scripts/convert_birefnet.py --variant lite --verify-only   # re-check the package already there

`--variant lite` (ZhengPeng7/BiRefNet_lite, Swin-T, 44 M parameters) is the
one Latent bundles. `general` and `portrait` (Swin-L, ~446 MB) are catalogue
rows: the script converts them into a folder the user adds through
Settings › AI › Models, once their revisions are pinned below.

What it does, step by step:

1. Downloads the PyTorch weights and the model code from Hugging Face at a
   pinned revision, and checks the SHA-256 of model.safetensors against the
   value recorded here, so a changed upload cannot silently change the
   bundled model.
2. Loads the model through transformers' trust_remote_code path (the repo
   ships its own birefnet.py: Swin backbone + BiRefNet decoder).
3. Replaces torchvision's deform_conv2d, which Core ML cannot express, with a
   pure-PyTorch formulation built from grid_sample (one bilinear resample per
   kernel tap, modulated, then a 1x1 conv). It is numerically the same op
   (max |diff| ~1e-4 in fp32); the decoder's ASPPDeformable blocks use it
   with kernel sizes 1, 3 and 7. The Swin blocks, attention, patch embed and
   merge, decoder and ASPP forwards are rewritten with every size laundered
   to a Python constant, because coremltools 9 cannot fold the shape
   arithmetic torch.jit.trace records; an eager equivalence check against the
   unpatched model guards the rewrites.
4. Wraps the model so its input is a plain RGB image (0-255) and the ImageNet
   normalisation happens inside the graph, and the final sigmoid is applied
   inside the graph too, so the app only resizes in and reads a [0, 1] soft
   mask out, at the same resolution as the input.
5. Traces with TorchScript and converts with coremltools to an ML Program in
   float16 targeting macOS 15. The in-process compute units are CPU_AND_GPU
   on purpose: the ANE compiler spends ~100 s on this graph and then every
   prediction fails ("Error in building plan"), so the manifest pins
   cpuAndGPU and ALL is never touched here.
6. Writes the .mlpackage and metadata, then verifies it against PyTorch (the
   unpatched torchvision model) on a test photo: max abs diff, IoU at 0.5,
   and timing at CPU_AND_GPU and CPU_ONLY. The plan's exit criteria (IoU on
   the GPU path >= 0.97, weight.bin under GitHub's 100 MiB file limit) fail
   the run.
7. Writes `<id>.model.json` last, through scripts/latent_manifest.py, with
   the package content hash and feature names read from the package.

A re-conversion is never byte-identical (coremltools serialises the weights
in a different order run to run), so the bundled package is converted once
and kept; a new conversion means a new hash and a new manifest.
"""
import argparse, datetime, hashlib, os, sys, time
import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import latent_manifest

REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]
LICENCE_URL = "https://github.com/ZhengPeng7/BiRefNet/blob/main/LICENSE"
# The largest weight.bin GitHub accepts as an ordinary blob; the bundled
# package must stay under it (docs/Retouch.md §5).
WEIGHT_LIMIT = 100 * 1024 * 1024

# Each variant is pinned to the Hugging Face repository revision that was
# vetted (git commit of the HF repo) and the SHA-256 of model.safetensors at
# that revision. A variant with no pin refuses to convert until someone has
# looked at the upload and recorded both.
VARIANTS = {
    "lite": dict(
        model="ZhengPeng7/BiRefNet_lite",
        revision="aa62cd87eafb9cc43056d08ef3615a14628b831d",
        weights_sha256="4417d89795250e698c3cb0ae8df15743810065f646f48a694fdfa7ca052d0815",
        backbone="swin_v1_t",
        name="BiRefNet_lite",
        id="birefnet-lite",
        display_name="BiRefNet Lite",
        purpose="Subject masks in one shot, no clicks needed",
    ),
    "general": dict(
        model="ZhengPeng7/BiRefNet",
        revision=None,
        weights_sha256=None,
        backbone="swin_v1_l",
        name="BiRefNet_general",
        id="birefnet-general",
        display_name="BiRefNet General",
        purpose="Subject masks: the full model, finest hair and structure",
    ),
    "portrait": dict(
        model="ZhengPeng7/BiRefNet-portrait",
        revision=None,
        weights_sha256=None,
        backbone="swin_v1_l",
        name="BiRefNet_portrait",
        id="birefnet-portrait",
        display_name="BiRefNet Portrait",
        purpose="Subject masks tuned for people",
    ),
}

parser = argparse.ArgumentParser()
parser.add_argument("--variant", choices=sorted(VARIANTS), default="lite")
parser.add_argument("--size", type=int, default=1024, help="square input size in pixels (the models are trained at 1024)")
parser.add_argument("--out", default=None,
                    help="directory for the package and manifest (default: the bundled Models folder for lite, "
                         "./<id>/ for the others)")
parser.add_argument("--test-image", default=None,
                    help="photo for the PyTorch comparison (default: TestAssets/HSB_6548.jpg, else the portrait)")
parser.add_argument("--skip-verify", action="store_true")
parser.add_argument("--verify-only", action="store_true",
                    help="no conversion: run the PyTorch comparison against the package already in --out")
parser.add_argument("--runs", type=int, default=5, help="timed predictions per compute unit after one warm-up")
args = parser.parse_args()

variant = VARIANTS[args.variant]
MODEL, REVISION, WEIGHTS_SHA256 = variant["model"], variant["revision"], variant["weights_sha256"]
if REVISION is None or WEIGHTS_SHA256 is None:
    sys.exit(f"--variant {args.variant} is not pinned yet: vet {MODEL}, then record its revision and the "
             f"SHA-256 of model.safetensors in VARIANTS before converting it")
LICENCE = f"MIT (https://huggingface.co/{MODEL}, model card: license: mit)"
out_dir = args.out or (os.path.join(REPO_ROOT, "Sources", "MLKit", "Resources", "Models")
                       if args.variant == "lite" else variant["id"])
package = os.path.join(out_dir, variant["name"] + ".mlpackage")
test_image_path = args.test_image
if test_image_path is None:
    for candidate in ("TestAssets/HSB_6548.jpg", "TestAssets/portrait/zena_cardman_nasa_portrait.jpg"):
        if os.path.isfile(os.path.join(REPO_ROOT, candidate)):
            test_image_path = os.path.join(REPO_ROOT, candidate)
            break
if test_image_path is None and not args.skip_verify:
    sys.exit("no test photo found under TestAssets; run scripts/fetch_test_assets.sh --portrait or pass --test-image")

t0 = time.time()

# ---------------------------------------------------------------- 1. download
print(f"Downloading {MODEL} @ {REVISION[:12]} …")
from huggingface_hub import snapshot_download
snapshot = snapshot_download(MODEL, revision=REVISION,
                             allow_patterns=["*.py", "*.json", "*.safetensors"])
weights = os.path.join(snapshot, "model.safetensors")
h = hashlib.sha256()
with open(weights, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
sha = h.hexdigest()
print(f"  model.safetensors sha256 {sha} ({os.path.getsize(weights)/1e6:.1f} MB)")
if sha != WEIGHTS_SHA256:
    sys.exit(f"SHA-256 mismatch: expected {WEIGHTS_SHA256}; refusing to convert")

# -------------------------------------------------------------------- 2. load
from transformers import AutoModelForImageSegmentation
model = AutoModelForImageSegmentation.from_pretrained(MODEL, revision=REVISION, trust_remote_code=True).eval()
cfg = model.config
print(f"  backbone {cfg.bb}, dec_att {cfg.dec_att}, {sum(p.numel() for p in model.parameters())/1e6:.1f} M parameters")
assert cfg.bb == variant["backbone"] and cfg.dec_att == "ASPPDeformable", "unexpected architecture for this revision"


# --------------------------------------------- 3. deformable conv replacement
birefnet_module = sys.modules[type(model).__module__]
_grid_cache = {}


def const_int(v):
    """Under torch.jit.trace a tensor's shape entries are 0-d tensors, and any
    arithmetic on them (H // 2, C // heads, torch.ceil(...)) is recorded into
    the graph as floor_divide + aten::Int, which coremltools 9 cannot fold
    into a scalar. Everything here is a fixed shape, so read the size out of
    the tracer and use it as a plain Python constant."""
    return int(v.tolist()) if isinstance(v, torch.Tensor) else int(v)


def hw(t):
    return const_int(t.shape[2]), const_int(t.shape[3])


def interp_to(t, ref):
    return F.interpolate(t, size=hw(ref), mode="bilinear", align_corners=True)


def _deform_forward(self, x):
    """Modulated deformable conv (DCNv2) via grid_sample, replacing
    torchvision.ops.deform_conv2d for the stride-1, dilation-1, single-group
    case BiRefNet uses. One bilinear resample per kernel tap, modulated, then
    accumulated through a 1x1 conv, so the peak intermediate stays at
    (1, C, H, W) instead of (1, k*k*C, H, W). The base sampling grids depend
    only on the feature size, so they are computed eagerly once per layer and
    size and traced as constants (no shape arithmetic in the graph)."""
    offset = self.offset_conv(x)
    modulator = 2.0 * torch.sigmoid(self.modulator_conv(x))
    weight = self.regular_conv.weight
    Cout, Cin = const_int(weight.shape[0]), const_int(weight.shape[1])
    kh, kw = self.regular_conv.kernel_size
    p = self.padding if isinstance(self.padding, int) else self.padding[0]
    H, W = hw(x)
    key = (id(self), H, W)
    if key not in _grid_cache:
        Ho, Wo = H + 2 * p - kh + 1, W + 2 * p - kw + 1
        ys = torch.arange(Ho, dtype=torch.float32) - p
        xs = torch.arange(Wo, dtype=torch.float32) - p
        by, bx = torch.meshgrid(ys, xs, indexing="ij")
        # grid_sample (align_corners=True) wants x, y normalised to [-1, 1]
        sx, sy = 2.0 / max(W - 1, 1), 2.0 / max(H - 1, 1)
        grids = [(bx + j) * sx - 1.0 for j in range(kw)], [(by + i) * sy - 1.0 for i in range(kh)]
        _grid_cache[key] = (Ho, Wo, grids[0], grids[1], sx, sy)
    Ho, Wo, base_x, base_y, sx, sy = _grid_cache[key]
    offset = offset.view(1, kh * kw, 2, Ho, Wo)      # [:, k, 0] = dy, [:, k, 1] = dx, k = i*kw + j
    out = None
    for i in range(kh):
        for j in range(kw):
            k = i * kw + j
            grid = torch.stack((base_x[j] + offset[:, k, 1] * sx, base_y[i] + offset[:, k, 0] * sy), dim=-1)
            sampled = F.grid_sample(x, grid, mode="bilinear", padding_mode="zeros", align_corners=True)
            sampled = sampled * modulator[:, k:k + 1]
            tap = F.conv2d(sampled, weight[:, :, i, j].reshape(Cout, Cin, 1, 1))
            out = tap if out is None else out + tap
    if self.regular_conv.bias is not None:
        out = out + self.regular_conv.bias.view(1, -1, 1, 1)
    return out


# ------------------------------------- 3b. shape-constant rewrites for tracing
# Same maths as the repo's birefnet.py (eval path only), with every size that
# feeds a view/reshape/interpolate laundered through const_int. The eager
# equivalence check below (patched vs original model) guards these rewrites.

def _window_partition(x, ws):
    B, H, W, C = (const_int(s) for s in x.shape)
    x = x.view(B, H // ws, ws, W // ws, ws, C)
    return x.permute(0, 1, 3, 2, 4, 5).contiguous().view(-1, ws, ws, C)


def _window_reverse(windows, ws, H, W):
    C = const_int(windows.shape[-1])
    x = windows.view(-1, H // ws, W // ws, ws, ws, C)
    return x.permute(0, 1, 3, 2, 4, 5).contiguous().view(-1, H, W, C)


def _window_attention_forward(self, x, mask=None):
    B_, N, C = (const_int(s) for s in x.shape)
    nh = self.num_heads
    qkv = self.qkv(x).reshape(B_, N, 3, nh, C // nh).permute(2, 0, 3, 1, 4)
    q, k, v = qkv[0], qkv[1], qkv[2]
    attn = (q * self.scale) @ k.transpose(-2, -1)
    bias = self.relative_position_bias_table[self.relative_position_index.view(-1)].view(N, N, -1)
    attn = attn + bias.permute(2, 0, 1).contiguous().unsqueeze(0)
    if mask is not None:
        nW = const_int(mask.shape[0])
        attn = (attn.view(B_ // nW, nW, nh, N, N) + mask.unsqueeze(1).unsqueeze(0)).view(-1, nh, N, N)
    attn = self.softmax(attn)
    x = (attn @ v).transpose(1, 2).reshape(B_, N, C)
    return self.proj(x)


def _swin_block_forward(self, x, mask_matrix):
    B, L, C = (const_int(s) for s in x.shape)
    H, W, ws = self.H, self.W, self.window_size
    shortcut = x
    x = self.norm1(x).view(B, H, W, C)
    pad_r, pad_b = (ws - W % ws) % ws, (ws - H % ws) % ws
    x = F.pad(x, (0, 0, 0, pad_r, 0, pad_b))
    Hp, Wp = H + pad_b, W + pad_r
    if self.shift_size > 0:
        shifted_x = torch.roll(x, shifts=(-self.shift_size, -self.shift_size), dims=(1, 2))
        attn_mask = mask_matrix
    else:
        shifted_x, attn_mask = x, None
    x_windows = _window_partition(shifted_x, ws).view(-1, ws * ws, C)
    attn_windows = self.attn(x_windows, mask=attn_mask).view(-1, ws, ws, C)
    shifted_x = _window_reverse(attn_windows, ws, Hp, Wp)
    x = torch.roll(shifted_x, shifts=(self.shift_size, self.shift_size), dims=(1, 2)) if self.shift_size > 0 else shifted_x
    if pad_r > 0 or pad_b > 0:
        x = x[:, :H, :W, :].contiguous()
    x = x.view(B, H * W, C)
    x = shortcut + x
    return x + self.mlp(self.norm2(x))


def _patch_merging_forward(self, x, H, W):
    B, L, C = (const_int(s) for s in x.shape)
    x = x.view(B, H, W, C)
    if H % 2 == 1 or W % 2 == 1:
        x = F.pad(x, (0, 0, 0, W % 2, 0, H % 2))
    x = torch.cat([x[:, 0::2, 0::2, :], x[:, 1::2, 0::2, :], x[:, 0::2, 1::2, :], x[:, 1::2, 1::2, :]], -1)
    return self.reduction(self.norm(x.view(B, -1, 4 * C)))


def _patch_embed_forward(self, x):
    H, W = hw(x)
    ph, pw = self.patch_size
    if W % pw != 0:
        x = F.pad(x, (0, pw - W % pw))
    if H % ph != 0:
        x = F.pad(x, (0, 0, 0, ph - H % ph))
    x = self.proj(x)
    if self.norm is not None:
        Wh, Ww = hw(x)
        x = self.norm(x.flatten(2).transpose(1, 2))
        x = x.transpose(1, 2).view(-1, self.embed_dim, Wh, Ww)
    return x


def _swin_forward(self, x):
    x = self.patch_embed(x)
    Wh, Ww = hw(x)
    assert not self.ape
    x = self.pos_drop(x.flatten(2).transpose(1, 2))
    outs = []
    for i in range(self.num_layers):
        x_out, H, W, x, Wh, Ww = self.layers[i](x, Wh, Ww)
        if i in self.out_indices:
            x_out = getattr(self, f"norm{i}")(x_out)
            outs.append(x_out.view(-1, H, W, self.num_features[i]).permute(0, 3, 1, 2).contiguous())
    return tuple(outs)


def _image2patches(image, ref):
    # einops 'b c (hg h) (wg w) -> b (c hg wg) h w' with hg, wg = image size // ref size
    B, C, H, W = (const_int(s) for s in image.shape)
    h, w = hw(ref)
    hg, wg = H // h, W // w
    x = image.view(B, C, hg, h, wg, w).permute(0, 1, 2, 4, 3, 5)
    return x.reshape(B, C * hg * wg, h, w)


def _forward_enc(self, x):
    cfg = self.config
    assert cfg.mul_scl_ipt == "cat" and cfg.cxt_num == 3 and cfg.bb not in ("vgg16", "vgg16bn", "resnet50")
    x1, x2, x3, x4 = self.bb(x)
    H, W = hw(x)
    x1_, x2_, x3_, x4_ = self.bb(F.interpolate(x, size=(H // 2, W // 2), mode="bilinear", align_corners=True))
    x1 = torch.cat([x1, interp_to(x1_, x1)], dim=1)
    x2 = torch.cat([x2, interp_to(x2_, x2)], dim=1)
    x3 = torch.cat([x3, interp_to(x3_, x3)], dim=1)
    x4 = torch.cat([x4, interp_to(x4_, x4)], dim=1)
    x4 = torch.cat((interp_to(x1, x4), interp_to(x2, x4), interp_to(x3, x4), x4), dim=1)
    return (x1, x2, x3, x4), None


def _aspp_deformable_forward(self, x):
    x1 = self.aspp1(x)
    deforms = [m(x) for m in self.aspp_deforms]
    x5 = interp_to(self.global_avg_pool(x), x1)
    x = self.conv1(torch.cat((x1, *deforms, x5), dim=1))
    return self.dropout(self.relu(self.bn1(x)))


def _decoder_forward(self, features):
    cfg = self.config
    assert cfg.dec_ipt and self.split and cfg.out_ref and not self.training
    x, x1, x2, x3, x4 = features
    x4 = torch.cat((x4, self.ipt_blk5(interp_to(_image2patches(x, x4), x4))), 1)
    p4 = self.decoder_block4(x4)
    p4 = p4 * self.gdt_convs_attn_4(self.gdt_convs_4(p4)).sigmoid()
    _p3 = interp_to(p4, x3) + self.lateral_block4(x3)
    _p3 = torch.cat((_p3, self.ipt_blk4(interp_to(_image2patches(x, _p3), x3))), 1)
    p3 = self.decoder_block3(_p3)
    p3 = p3 * self.gdt_convs_attn_3(self.gdt_convs_3(p3)).sigmoid()
    _p2 = interp_to(p3, x2) + self.lateral_block3(x2)
    _p2 = torch.cat((_p2, self.ipt_blk3(interp_to(_image2patches(x, _p2), x2))), 1)
    p2 = self.decoder_block2(_p2)
    p2 = p2 * self.gdt_convs_attn_2(self.gdt_convs_2(p2)).sigmoid()
    _p1 = interp_to(p2, x1) + self.lateral_block2(x1)
    _p1 = torch.cat((_p1, self.ipt_blk2(interp_to(_image2patches(x, _p1), x1))), 1)
    _p1 = interp_to(self.decoder_block1(_p1), x)
    _p1 = torch.cat((_p1, self.ipt_blk1(interp_to(_image2patches(x, _p1), x))), 1)
    return [self.conv_out1(_p1)]


# The Swin BasicLayer builds its shifted-window attention mask with
# torch.ceil(torch.tensor(H) / ws) and in-place slice fills. The mask depends
# only on (H, W, window, shift), all fixed at trace time, so compute it once
# eagerly per layer and size and let the tracer capture it as a constant.
# (Each layer sees two sizes: the backbone also runs on a half-res copy
# because mul_scl_ipt == 'cat'.)
_attn_mask_cache = {}


def _basic_layer_forward(self, x, H, W):
    H, W = const_int(H), const_int(W)
    key = (id(self), H, W)
    if key not in _attn_mask_cache:
        ws, ss = self.window_size, self.shift_size
        Hp, Wp = -(-H // ws) * ws, -(-W // ws) * ws
        img_mask = torch.zeros((1, Hp, Wp, 1))
        cnt = 0
        for h in (slice(0, -ws), slice(-ws, -ss), slice(-ss, None)):
            for w in (slice(0, -ws), slice(-ws, -ss), slice(-ss, None)):
                img_mask[:, h, w, :] = cnt
                cnt += 1
        mw = _window_partition(img_mask, ws).view(-1, ws * ws)
        am = mw.unsqueeze(1) - mw.unsqueeze(2)
        _attn_mask_cache[key] = am.masked_fill(am != 0, -100.0).masked_fill(am == 0, 0.0)
    attn_mask = _attn_mask_cache[key].to(x.dtype)
    for blk in self.blocks:
        blk.H, blk.W = H, W
        x = blk(x, attn_mask)
    if self.downsample is not None:
        x_down = self.downsample(x, H, W)
        return x, H, W, x_down, (H + 1) // 2, (W + 1) // 2
    return x, H, W, x, H, W


def apply_tracing_patches():
    m = birefnet_module
    m.DeformableConv2d.forward = _deform_forward
    m.window_partition = _window_partition
    m.window_reverse = _window_reverse
    m.WindowAttention.forward = _window_attention_forward
    m.SwinTransformerBlock.forward = _swin_block_forward
    m.PatchMerging.forward = _patch_merging_forward
    m.PatchEmbed.forward = _patch_embed_forward
    m.SwinTransformer.forward = _swin_forward
    m.BasicLayer.forward = _basic_layer_forward
    m.ASPPDeformable.forward = _aspp_deformable_forward
    m.BiRefNet.forward_enc = _forward_enc
    m.Decoder.forward = _decoder_forward


# --------------------------------------------------------------------- 4. wrap
class Wrapped(torch.nn.Module):
    """RGB 0-255 in, soft foreground mask in [0, 1] at the input resolution out."""
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1) * 255)
        self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1) * 255)

    def forward(self, image):
        x = (image - self.mean) / self.std
        logits = self.net(x)[-1]            # list of scaled predictions; last is full-res (1, 1, H, W)
        return torch.sigmoid(logits)


wrapped = Wrapped(model).eval()
example = torch.rand(1, 3, args.size, args.size) * 255

reference = None
if not args.skip_verify:
    # PyTorch reference with the ORIGINAL torchvision deform_conv2d, before patching.
    from PIL import Image
    test_img = Image.open(test_image_path).convert("RGB").resize((args.size, args.size), Image.BILINEAR)
    test_t = torch.from_numpy(np.asarray(test_img, dtype=np.float32)).permute(2, 0, 1)[None]
    print(f"PyTorch reference on {os.path.relpath(test_image_path, REPO_ROOT)} …")
    with torch.no_grad():
        reference = wrapped(test_t)[0, 0].numpy()

if not args.verify_only:
    apply_tracing_patches()
    if reference is not None:
        with torch.no_grad():
            patched = wrapped(test_t)[0, 0].numpy()
        diff = np.abs(patched - reference).max()
        print(f"  patched model (grid_sample deform conv + shape-constant rewrites) vs original, fp32: max |diff| {diff:.2e}")
        assert diff < 1e-3, "tracing rewrites changed the model's output"

    print("Tracing …")
    with torch.no_grad():
        wrapped(example)      # eager pass fills the attention-mask cache before tracing
        traced = torch.jit.trace(wrapped, example, check_trace=False)

    # -------------------------------------------------------------- 5. convert
    print("Converting to Core ML …")
    t1 = time.time()
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, args.size, args.size),
                             color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="mask")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_GPU,     # never touch the ANE compiler in-process
        minimum_deployment_target=ct.target.macOS15,
    )
    print(f"  converted in {time.time()-t1:.0f}s")
    mlmodel.short_description = f"{variant['name']} subject/background segmentation: RGB image in, soft foreground mask [0,1] out"
    mlmodel.author = "Latent"
    mlmodel.license = LICENCE
    mlmodel.user_defined_metadata["author"] = "Latent"
    mlmodel.user_defined_metadata["source"] = f"https://huggingface.co/{MODEL}"
    mlmodel.user_defined_metadata["license"] = LICENCE
    mlmodel.user_defined_metadata["revision"] = REVISION
    mlmodel.user_defined_metadata["weights_sha256"] = WEIGHTS_SHA256
    mlmodel.user_defined_metadata["input_size"] = str(args.size)
    mlmodel.user_defined_metadata["input"] = "image: RGB 0-255, ImageNet normalisation is inside the graph"
    mlmodel.user_defined_metadata["output"] = "mask: (1, 1, H, W) float, sigmoid applied inside the graph, 1 = foreground"
    mlmodel.user_defined_metadata["notes"] = "torchvision deform_conv2d replaced by an equivalent grid_sample formulation"

    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(package)
    size_mb = latent_manifest.package_size(package) / 1e6
    print(f"Wrote {package} ({size_mb:.1f} MB) in {time.time()-t0:.0f}s")

# ------------------------------------------------------------------- 6. verify
weight_bin = os.path.join(package, "Data", "com.apple.CoreML", "weights", "weight.bin")
weight_bytes = os.path.getsize(weight_bin)
print(f"  weight.bin {weight_bytes:,} bytes = {weight_bytes / (1 << 20):.1f} MiB (limit {WEIGHT_LIMIT >> 20} MiB)")
failed = weight_bytes >= WEIGHT_LIMIT
if not args.skip_verify:
    print("Verifying …")

    def iou(a, b, thr=0.5):
        a, b = a > thr, b > thr
        return (a & b).sum() / max((a | b).sum(), 1)

    for cu in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_ONLY):
        t2 = time.time()
        loaded = ct.models.MLModel(package, compute_units=cu)
        load_s = time.time() - t2
        out = loaded.predict({"image": test_img})["mask"]        # warm-up
        times = []
        for _ in range(args.runs):
            t3 = time.time(); out = loaded.predict({"image": test_img})["mask"]; times.append(time.time() - t3)
        got = np.asarray(out, dtype=np.float32)[0, 0]
        score = iou(got, reference)
        print(f"  {cu.name:12s} load {load_s:.1f}s  predict {np.median(times)*1000:.0f} ms median "
              f"(min {min(times)*1000:.0f}, max {max(times)*1000:.0f}, {args.runs} runs after warm-up)  "
              f"output {out.shape} {out.dtype}")
        print(f"               vs PyTorch fp32: max |diff| {np.abs(got - reference).max():.4f}, "
              f"mean |diff| {np.abs(got - reference).mean():.5f}, IoU@0.5 {score:.4f}, "
              f"pixels flipped at 0.5: {((got > 0.5) != (reference > 0.5)).mean()*100:.3f}%")
        # The app runs the GPU path (the manifest pins cpuAndGPU), so that is
        # the one the plan's IoU criterion applies to.
        if cu == ct.ComputeUnit.CPU_AND_GPU and score < 0.97:
            print(f"  FAILED: IoU {score:.4f} on the GPU path is under 0.97")
            failed = True
if failed:
    sys.exit("Verification failed; no manifest written")
if args.verify_only:
    print("Verified")
    sys.exit(0)

# ----------------------------------------------------------------- 7. manifest
row = latent_manifest.package_entry(package)
row["_bytes"] = latent_manifest.package_size(package)
manifest = latent_manifest.build_manifest(
    id=variant["id"], display_name=variant["display_name"], purpose=variant["purpose"], version=1,
    kind="subjectSegmentation", licence_name="MIT", licence_url=LICENCE_URL, commercial_use=True,
    source_url=f"https://huggingface.co/{MODEL}", input_size=args.size, packages=[row],
    output_activation="probabilities", refine="none", compute_units="cpuAndGPU",
    converter={"script": "scripts/convert_birefnet.py", "sourceRevision": REVISION,
               "coremltools": ct.__version__, "torch": torch.__version__.split("+")[0],
               "date": datetime.date.today().isoformat()})
print(f"Wrote {latent_manifest.write_manifest(manifest, out_dir)}")
