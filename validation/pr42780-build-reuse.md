# PR 42780 build-reuse record

## Pre-build classification for `516b449c4a6a2f5e7a1099ada6207ad4347be909`

- Previous candidate source: `06d70f151668a69af64c2e6f2004ed8aa7d062fd`
- Candidate source: `516b449c4a6a2f5e7a1099ada6207ad4347be909`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 06d70f151668a69af64c2e6f2004ed8aa7d062fd..516b449c4a6a2f5e7a1099ada6207ad4347be909`
- Full changed-path result: 309 paths; SHA-256 `182afacd851100092ac6781b4d1ccf222eb372deba285e45901c565afdcf53b7`
- Whitespace-only equivalence: false
- Candidate archive SHA-256: `be59809480b0c83b17e2b915731c35fdceb483c10b6f1de793505b6240ef8ba0`

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `true` | The exact path-limited comparison over `pr42780-native-inputs.txt` found `python/pyproject.toml` changed after rebasing onto current upstream `main`. Reusing the prior TreeCore artifact is therefore prohibited. |
| `python_behavior_changed` | `true` | The candidate adds correlated recovery-hop diagnostics, structured recovery timeout handling, and same-operation reconciliation regressions. |
| `formatting_only` | `false` | The candidate contains behavioral and upstream changes and is not whitespace-equivalent. |

### Selected reuse path

- Reuse immutable Mooncake runtime `ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:61125246daa7194fa993b631a5012d61d7c4c79befc85f1e4e2311b57ff236a3`.
- Select `runtime-reuse-mooncake`: Mooncake is outside the dependency graph, while `pr-rust-builder` rebuilds TreeCore from the candidate's declared native inputs.
- Record the new TreeCore artifact digest, native-input digest, and producing commit in the image itself through `build-metadata.env`.
- Do not select `runtime-reuse-mooncake-and-treecore`; the changed `python/pyproject.toml` makes that path invalid for this head.
- Do not use a GHA cache. The immutable GHCR Mooncake runtime is the cache boundary, avoiding both the hour-scale Mooncake compile and the previously dominant `mode=max` cache export.
- Do not run disk reclamation. The selected graph needs only the TreeCore toolchain/build scratch space and the final Python overlay.

### Most recent Python-only build `39695859298`

- Runnable AMD64 digest: `sha256:fec92c82f5d48fc6fedf69c487b5194c9d54a668d7be445448ea6bd8821c605e`
- Build index digest: `sha256:3fec3a01da847941d42890d446db44774d8c1c15dfbfe45f2883fb86c79f3285`
- Total duration: about 15m27s.
- That build reused both Mooncake and TreeCore because its native inputs were unchanged. The present build must additionally compile TreeCore, whose prior measured compile took about 83 seconds.

## Post-build record

Pending workflow completion. Record the workflow SHA, index and AMD64 digests, reused Mooncake digest, candidate PR SHA, new TreeCore artifact/input digests, observed registry transfer/export duration, total build duration, and any divergence from the plan above.
