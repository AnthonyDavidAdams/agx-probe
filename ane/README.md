# ane/ — Apple Neural Engine probes

Same method as the GPU work, pointed at the Neural Engine. On this machine the
ANE reports itself as **`h16g`, 16 cores** (`ANEVersion` 192.17).

## The ANE's op vocabulary

`ANECompiler.framework` exports one `ANEC<Name>LayerDescInitialize` symbol per
layer type it can compile. That is the Neural Engine's whole vocabulary, readable
straight out of the shipping binary — **44 layer types**, in `ane-layer-types.txt`.

Several are not obvious from Core ML's public surface: `GOC`, `DynamicGOC`,
`RingBufferWriter`, `CrossCorrelation`, `MinMaxNorm`, `InputView`, `Random`.

## Dispatch is whole-graph and work-gated

Core ML decides per model — not per operation — whether work reaches the ANE,
and the decision is **all or nothing**. `MLComputePlan` reports the assignment.

```
(a) depth sweep, C=32 HW=64 fp16     (b) depth FIXED at 2
    depth 1   CPU                        C=64          ANE
    depth 2   CPU                        C=128         ANE
    depth 3   ANE   <- flips             C=256         ANE
    depth 4   ANE                        C=128 HW=128  ANE
    depth 16  ANE
```

Depth 2 at C=32 stays on CPU while depth 2 at C=64 moves to ANE, so the trigger
is **total work, not depth and not op type**. Depth was only a proxy that
crossed the threshold first. When the graph does move, everything moves —
including the `cast` ops at the boundary.

### Consequence worth knowing

**Single-op microbenchmarks report that the ANE supports nothing.** All 25
single-operation models here — `conv3x3` included — are assigned entirely to CPU.
The ANE unquestionably runs convolutions; the graph was just too small to be
worth dispatching. Anyone profiling one op at a time to discover ANE support
will measure the scheduler's overhead policy and mistake it for a capability
limit.

## Files

```
gen_models.py    25 single-operation models (fp32 or fp16)
gen_deep.py      stacked conv+relu at increasing depth
gen_thresh.py    separates depth from total work
ane_probe.m      walks MLComputePlan, reports per-op compute device
```

`const` operations return no device; they are counted separately as `NIL` rather
than silently folded into CPU, which was a real bug in the first version of this
tool and made every model look CPU-bound.

## Requirements

coremltools needs a Python with native wheels — 3.11 works, 3.14 does not
(the compiled storage module is simply absent and model export fails with
`BlobWriter not loaded`).

```sh
python3.11 -m venv ~/.ane-venv && ~/.ane-venv/bin/pip install coremltools numpy
~/.ane-venv/bin/python gen_thresh.py thresh
clang -fobjc-arc -O2 -o ane_probe ane_probe.m -framework Foundation -framework CoreML
./ane_probe thresh
```
