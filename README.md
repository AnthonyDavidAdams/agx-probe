# agx-probe

Recovering undocumented GPU state layout and instruction encodings on Apple
silicon by differential experiment, on a stock MacBook Air, with System
Integrity Protection enabled.

Apple publishes no documentation for the AGX GPU. The only description of its
command format that exists is Apple's own driver, expressed as behaviour. These
tools reconstruct part of that format empirically: change exactly one piece of
state, capture the bytes the driver sends the GPU, and diff.

Tested on **Apple M4 (AGX G16G, `AGXMetalG16G_B0`), macOS 15.6**.

## Validated by control, not correlation

Every offset below is inferred from correlation — change a state, watch bytes
move. `write_probe` closes that gap. It calibrates the location of
`depthCompareFunction` at runtime, then **overwrites that byte in GPU-visible
memory at commit** and checks the rendered image.

```
Triangle at z=0.0, depth buffer cleared to 0.5. Coverage = % of frame lit.

CONDITION                          PATCHED  COVERAGE  VERDICT
API=Always, unpatched              -           41.1%  visible
API=Never,  unpatched              -            0.0%  absent
--------------------------------------------------------------
API=Always, PATCHED to Never       2            0.0%  SUPPRESSED
API=Never,  PATCHED to Always      2           41.1%  RESTORED
```

The image follows the patched byte, not the API call, in **both directions**.
The recovered field drives the hardware.

`validate_all` generalises this into a table-driven test with a strict
predicate: **patching A→B must produce a framebuffer pixel-identical to an
unpatched render of B.** No per-field expectations — exact equality or nothing.
Candidate sites are found differentially over an 8-bit shift search, then
narrowed by bisection, so the tool names the *specific* causal byte.

```
FIELD                  SITES  cov(A)  cov(B)  cov(A->B)  VERDICT
depthCompareFunction   2      25.8%    0.0%     0.0%     CAUSAL @ reg26 0x93b bit0   (3 probes)
cullMode               1      25.8%    0.0%     0.0%     CAUSAL @ reg26 0x998 bit0   (2 probes)
frontFacingWinding     88     25.8%    0.0%     0.0%     CAUSAL @ reg26 0x99a bit0   (9 probes)
stencilPassOp          392    25.8%   25.8%    25.8%     CAUSAL @ reg26 0x93e bit0  (11 probes)
scissor.x              1      25.8%   17.0%    17.0%     CAUSAL @ reg19 0x012       (2 probes)
blendColor.red         1      25.8%   25.8%    25.8%     CAUSAL @ reg21 0x620       (2 probes)
triangleFillMode       407    25.8%    3.4%      -       altered output, never reproduced B
stencilCompareFunc     50     25.8%    0.0%      -       patching had no effect
depthWriteEnabled      6      25.8%   25.8%      -       patching had no effect
```

Note `stencilPassOp` and `blendColor.red` pass with **identical coverage** — the
pixel-exact hash catches them because colour changed the predicted way while the
silhouette did not. A coverage-only metric would have called both untestable.

Bisection matters: isolating one causal byte out of 88 candidates takes 9
renders instead of 88, and the full run is under half a second. Patching all
candidates at once instead corrupts unrelated state and produces false
negatives.

Two failures are findings rather than noise. `triangleFillMode` patching *does*
change the image but never reproduces line-fill exactly, so the mode is not
carried by that bit alone. `stencilCompareFunc` has 50 candidate sites and
patching none of them changes anything, which suggests a separate
stencil-enable gates it — changing the field without the enable is inert.

This is the difference between a map and a driver: not "this byte correlates
with depth testing" but "writing this byte controls depth testing." Two fields
are causally validated so far; the rest of the map remains correlational until
each gets the same treatment.

Run it with `make validate`.

## Results

### Depth/stencil descriptor — 8 bytes per face

Front face at `+0x938`, back face at `+0x940`. The two records are identical in
layout, which is what identifies the structure.

```
+0        stencilReferenceValue      uint8 (byte 0 of LE int)
+3        depthCompareFunction       3-bit @ bit 0, identity
+4        stencilWriteMask           uint8
+5        stencilReadMask            uint8
+6..+7    packed 16-bit LE word:
            bits  0..2   stencilPassOp
            bits  3..5   depthFailOp
            bits  6..8   stencilFailOp     <- spans the byte boundary
            bits  9..11  stencilCompareFunction
```

All four stencil enums are identity-encoded 3-bit fields packed consecutively.
`stencilFailOp` straddles `0x93e`/`0x93f`, which is why byte-at-a-time
extraction misses it.

### Contiguous scalar blocks

```
depthBias / slopeScale / clamp     +0x000  +0x004  +0x008     float32 x3
blendColor RGBA                    +0x680 .. +0x68c           float32 x4
viewport znear / zfar              +0x980  +0x984             float32 x2
viewport scale (= width / 2)       +0x970                     float32
scissor x / y                      +0x012  +0x016             LE int
```

Viewport is stored as **scale**, not extent: sweeping width `8 16 32 48 64`
yields `4 8 16 24 32`.

### Encoder state

```
cullMode              +0x998   2-bit @ bit 0, with bit 7 set  (0x80 | mode)
frontFacingWinding    +0x99a   identity
depthWriteEnabled     +0x484   1-bit @ bit 3   (replicated at many sites)
triangleFillMode      +0x6ec   1-bit @ bit 3   (replicated)
depthClipMode         +0x79c   1-bit @ bit 3   (replicated)
```

### Instruction cost tiers (isa_probe)

Compiling compute kernels that differ in one operation and measuring the code
slot Apple's compiler emits:

```
193-194 bytes   add sub mul min max fma abs        single ALU instruction
257-258 bytes   div sqrt rsqrt floor ceil exp2 log2  special-function unit
321 bytes       sin                                  range reduction
```

A clean 64-byte quantum separates the tiers, which is allocation granularity
rather than instruction size.

Diffing **within** a size class (slots of different length sit at different
alignments, so cross-size diffs compare unrelated bytes) localizes the
instruction encoding to roughly `+0xa0..+0xa7` of the slot:

```
194-byte group      mul    min    max    abs
  +0x0a2             1d     1e     1e     1c      operation class
  +0x0a4             00     01     00     02      discriminator
```

`min` and `max` share an operation-class byte and differ by a **single bit** at
`+0x0a4`. This is a candidate instruction word, not a verified opcode map — it
locates where the encoding lives and shows one bit doing real work. Turning it
into a disassembler needs round-trip validation against hardware, which this
repository does not yet do.

### Blending has no register

Sweeping blend factors produces **variable-length shader code**, not a field:
193 bytes when the mode reads only the source, 258 when it must also fetch the
destination or the blend constant. Apple's compiler lowers blending into the
fragment shader. This matches how Mesa's Asahi driver handles blending, and is
the clearest example of the method correctly reporting that a thing you expected
to find does not exist.

## Pipeline-state axes: state or compiled code?

Thirteen axes came back `not located` from `state_probe` because they live in
the pipeline object, so changing one recompiles the shader. `pso_probe` asks a
sharper question — is the axis carried by a fixed-size descriptor slot, or baked
into code?

```
AXIS                 SLOT SIZES        VERDICT
vertex.attrOffset    322,322,322       STATE: 4 bytes differ, first at +0x99
blend.srcFactor      514,514,514,514   CODE (271 of 514 bytes differ)
colorWriteMask       449,386,385,450   CODE (slot size varies with value)
vertex.format        258,322,322,321   CODE
vertex.layoutStride  258,321,322       CODE
blend.dstFactor      514,577,513,578   CODE
```

`blend.srcFactor` is the clean case: **constant 514-byte slot, but 271 of those
bytes move.** A state field shifts a handful of bytes; that is a recompile. So
most of the thirteen are not gaps in the map — they are provably not registers.

## Instruction format

`isa2_probe` compiles kernels differing in one immediate or one operand and
diffs the emitted slots. Slots must first be snapped to the **64-byte quantum**;
a one-byte start difference (193 vs 194) otherwise makes every later byte
compare unequal, which turned a 3-byte difference into a 99-byte one.

```
=== immediate ===        1.5   2.5   3.5   4.5   5.5
  +0x093                  b9    c5    cd    d3    d7      the literal
  +0x0c0/c1            varies                             likely a hash

=== operand order ===   a-b   b-a   a-c   c-a
  +0x088                 01    02    01    02
  +0x096                 02    01    02    01             source operands, swapped
```

Immediates are **one byte**, not inline float32, and the deltas (+12,+8,+6,+4)
decay logarithmically — a minifloat encoding rather than a constant pool index.
`+0x088` and `+0x096` hold source operands and swap when the operands swap; they
are identical for `a-b` and `a-c` because the register allocator reuses registers
regardless of which buffer is read.

## Firmware ring

`ring_probe` looks one layer below everything else: the coprocessor the GPU is
actually driven by. Over 24 submits it looks for monotonic counters and write
windows that march.

```
reg6 +0x004 / +0x008    352 -> 2376, constant stride, +88 per submit
reg6 0x16c, 0x198, ...  44-byte records, two counters each (stride 0x2c)
reg30                   write window marches +101,376 bytes over 23 submits
```

A pointer pair advancing in lockstep at a fixed stride is the head/tail
signature, and reg30's marching window is a ring data area. Located, not
decoded.

## Neural Engine

The same method applied to the ANE (`h16g`, 16 cores) lives in [`ane/`](ane/):
the Neural Engine's full 44-entry layer vocabulary extracted from
`ANECompiler.framework`, and the finding that **Core ML's ANE dispatch is a
whole-graph, all-or-nothing decision gated on total work** — which is why
single-op microbenchmarks conclude the ANE supports nothing at all.

## How it works

1. **Hook `-[AGXG16GFamilyCommandBuffer commit]`.** Metal encoding is lazy —
   nothing reaches GPU memory until commit. The driver bundle loads from disk
   and is Objective-C, so it is swizzleable; `DYLD_INTERPOSE` cannot reach it,
   because calls inside the dyld shared cache are pre-bound.
2. **Snapshot `VM_MEMORY_IOACCELERATOR` regions** at that instant.
3. **Build a noise mask** by running the identical draw twice and permanently
   excluding every byte that differs anyway. Typically ~68 bytes of 3.7 MB.
   Skip this and every later diff is unreadable.
4. **Sweep one axis at a time**, classify each surviving offset against the
   sweep, and derive the encoding.

Capture is necessarily serial — it snapshots process-global memory, so
concurrent work would destroy the isolation. Analysis is parallel (GCD), and
the two probes run as independent processes.

## Build and run

```sh
make            # builds build/state_probe and build/isa_probe
make run        # runs both concurrently, writes to results/
```

No entitlements, no kernel extensions, no disabled security, no second machine.

## Limits

- **Region indices are ordinal, not identifiers.** They shift between runs.
  Offsets within a descriptor are stable; region numbers are not.
- Offsets were not tested across reboots or OS versions. Treat this as a map of
  structure, not of fixed addresses.
- `MTLCompareFunctionNever` is excluded throughout: it produces a degenerate
  command stream that swamps the field being measured.
- Anything living in the pipeline state object (vertex formats, colour write
  mask) triggers a shader recompile whose structural difference drowns the
  field. Those axes report `not located` and need a different approach.
- Sampler address modes, LOD clamps and anisotropy are not yet located.

## What this cannot do

This maps **state**. It cannot map the **instruction set** beyond gross code
size, nor the **firmware ring protocol** the GPU coprocessor actually speaks.
Those are the bulk of a real driver and each needs its own instrument.

## Prior art

The method is the one [Asahi Linux](https://asahilinux.org/) used to bring up
Apple silicon, and the [Mesa](https://www.mesa3d.org/) Asahi driver is the
reference for what a finished version of this work looks like. This repository
is a small, automated re-derivation on newer silicon, not a driver.

## License

MIT
