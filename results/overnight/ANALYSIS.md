# Overnight reproducibility, 2,399 runs over 9 hours

Each validator ran continuously; a field counts only where the *offset* matches.

| Field | Probe | Runs seen | Hit rate | Offset(s) |
|---|---|---:|---:|---|
| `sampler.tAddressMode` | validate_sampler | 219/219 | **100.0%** | `0x664` |
| `sampler.sAddressMode` | validate_sampler | 219/219 | **100.0%** | `0x663` |
| `sampler.mipFilter` | validate_sampler | 219/219 | **100.0%** | `0x663` |
| `sampler.compareFunction` | validate_sampler | 219/219 | **100.0%** | `0x684` |
| `sampler.borderColor` | validate_sampler | 219/219 | **100.0%** | `0x667` |
| `depthCompareFunction` | validate_all | 220/221 | **99.5%** | `0x00093b` |
| `cullMode` | validate_all | 220/221 | **99.5%** | `0x000998` |
| `clearDepth` | validate_pass | 217/219 | **99.1%** | `0xecf` |
| `stencilReferenceValue` | validate_pass | 208/219 | **95.0%** | `0x1338` |
| `clearStencil` | validate_pass | 205/219 | **93.6%** | `0xed0` |
| `renderTargetWidth` | validate_pass | 202/219 | **92.2%** | `0x136a 0x136b 0x136e 0x136f` |
| `triangleFillMode` | validate_all | 134/221 | **60.6%** | `0x93a` |
| `stencilPassOp` | validate_all | 134/221 | **60.6%** | `0x00093e` |
| `stencilFailOp` | validate_all | 134/221 | **60.6%** | `0x00093e` |
| `stencilCompareFunc` | validate_all | 134/221 | **60.6%** | `0x936 0x93f` |
| `scissor.y` | validate_all | 134/221 | **60.6%** | `0x000016` |
| `scissor.x` | validate_all | 134/221 | **60.6%** | `0x000012` |
| `renderTargetWidth` | validate_all | 134/221 | **60.6%** | `0x972 0x973 0x976 0x977` |
| `frontFacingWinding` | validate_all | 134/221 | **60.6%** | `0x00099a` |
| `depthWriteEnabled` | validate_all | 134/221 | **60.6%** | `0x93a` |
| `depthFailOp` | validate_all | 134/221 | **60.6%** | `0x00093e` |
| `clearColor.red` | validate_all | 134/221 | **60.6%** | `0x0000e0` |
| `clearColor.green` | validate_all | 134/221 | **60.6%** | `0x0000e4` |
| `clearColor.blue` | validate_all | 134/221 | **60.6%** | `0x0000e8` |
| `clearColor.alpha` | validate_all | 134/221 | **60.6%** | `0x0000ec` |
| `blendColor.red` | validate_all | 134/221 | **60.6%** | `0x000620` |
| `blendColor.green` | validate_all | 134/221 | **60.6%** | `0x000624` |
| `blendColor.blue` | validate_all | 134/221 | **60.6%** | `0x000628` |
| `sampler.magFilter` | validate_sampler | 52/219 | **23.7%** | `0x662` |
| `sampler.minFilter` | validate_sampler | 51/219 | **23.3%** | `0x663` |
| `stencil.loadAction` | validate_pass | 1/219 | **0.5%** | `0xccd` |
