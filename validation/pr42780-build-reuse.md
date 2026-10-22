# PR 42780 build-reuse record

## Pre-build classification for `e658396f16f112cfd5daeea3a3fd444335930a62`

- Previous candidate source: `1dfa54b0e895962f59211ba1842a64f968ef91f6`
- Candidate source: `e658396f16f112cfd5daeea3a3fd444335930a62`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 1dfa54b0e895962f59211ba1842a64f968ef91f6..e658396f16f112cfd5daeea3a3fd444335930a62`
- Full changed-path result: 11 paths; SHA-256 `bcc8024c14eb0f5925700d955aaccd465487ec90bdff7ee661883c37b215be43`
- Whitespace-only equivalence: false
- Candidate archive SHA-256: `89004aa2b1a8fd953e96e025b97851a6b104d4eae295f53d48a4f66e16c7f597`

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `false` | The exact path-limited comparison over `pr42780-native-inputs.txt` returned no paths. |
| `python_behavior_changed` | `true` | Recovery warmup now normalizes and verifies its internal sampling parameters before entering `ScheduleBatch`; the regression executes the previously crashing string-stop check. |
| `formatting_only` | `false` | The candidate contains behavioral changes and is not whitespace-equivalent. |

### Selected reuse path

- Reuse immutable full runtime `ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:8b908926eb3d03ddfc25b9e9116555b6602fa4ee096a450bb00724917c677bee`.
- Select `runtime-reuse-mooncake-and-treecore`; neither native build graph is reachable from this target.
- Reuse TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, native-input digest `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`, produced by `516b449c4a6a2f5e7a1099ada6207ad4347be909`.
- Do not run disk reclamation or export a GHA build cache. The immutable GHCR runtime remains the cache boundary.
- Expected duration is about 15 minutes, dominated by source download, SBOM, attestation, and OCI export rather than compilation.

### Post-build record

- Workflow run: `39842504887`
- Validation commit: `1702d88bbdd9ece5a3c2fc88cc5f3471ff70cd87`
- Result: success in 15m45s.
- Build index digest: `sha256:229837ec58997ee43d660982a00e987a029f41752228df2c4c0449fc4b962012`
- Runnable Linux AMD64 digest: `sha256:94779da8de505a93648bb6ed4a6c716c0c164da53bd2c5a8213a54f5ecd1afec`
- Attestation manifest: `sha256:f81b34b6b04cfaaeda4cfd1b1471a7513a8ef821379b5b194fbd718d1ad902ed`
- Published image labels record PR revision `e658396f16f112cfd5daeea3a3fd444335930a62`, reused runtime digest `sha256:8b908926eb3d03ddfc25b9e9116555b6602fa4ee096a450bb00724917c677bee`, Mooncake commit `1c54e233a22404692efd312739db749991d8d757`, CUDA architecture `100`, TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, and native-input digest `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`.
- The BuildKit graph selected `runtime-reuse-mooncake-and-treecore`; neither `pr-rust-builder` nor `mooncake-builder` executed. The reused production TreeCore loaded from the embedded PR source with `SGLANG_RUST_BUILD_MODE=never`.
- Manifest pushes took 1.6s and 0.7s; SBOM/attestation export remained the dominant final-stage cost.

## Pre-build classification for `1dfa54b0e895962f59211ba1842a64f968ef91f6`

- Previous candidate source: `31a9275785295336a36961604772deccdd92a982`
- Candidate source: `1dfa54b0e895962f59211ba1842a64f968ef91f6`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 31a9275785295336a36961604772deccdd92a982..1dfa54b0e895962f59211ba1842a64f968ef91f6`
- Full changed-path result: 6 paths; SHA-256 `1601f49e5ff099bed550140249a02e5d73a41d12eb53d24e8e7a2d4247fb35c3`
- Whitespace-only equivalence: false
- Candidate archive SHA-256: `f65a006582d900d6e95ed82aceae7b8a6af1dec7a85f0e9dacdcbbd2db5c7aa7`

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `false` | The exact path-limited comparison over `pr42780-native-inputs.txt` returned no paths. |
| `python_behavior_changed` | `true` | The tokenizer now commits correlated `awaiting_recovery` state before acknowledging an accepted survivor quorum; the real-route regression verifies the HTTP-visible snapshot before recovery submission. |
| `formatting_only` | `false` | The candidate contains behavioral changes and is not whitespace-equivalent. |

### Selected reuse path

- Reuse immutable full runtime `ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:95ae1606f049770da3e44895f6be347d0bcb0226cde9c2b5f769c4e3175c960f`.
- Select `runtime-reuse-mooncake-and-treecore`; neither native build graph is reachable from this target.
- Reuse TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, native-input digest `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`, produced by `516b449c4a6a2f5e7a1099ada6207ad4347be909`.
- Do not run disk reclamation or export a GHA build cache. The immutable GHCR runtime remains the cache boundary.

### Post-build record

- Workflow run: `39830219372`
- Validation commit: `86d3cbfe2900e153ed488c93bbaf1ee193e63265`
- Result: success in 13m30s.
- Build index digest: `sha256:e5079b5dd843bf9f66805cccc544899fccd002a383a7fc57d69586e74db8b711`
- Runnable Linux AMD64 digest: `sha256:8b908926eb3d03ddfc25b9e9116555b6602fa4ee096a450bb00724917c677bee`
- Attestation manifest: `sha256:a8da8d7b6ea811b1913a2153f486beb746263bdbd1f3eaf88e8e3cfa63a0b1a4`
- Published image labels record PR revision `1dfa54b0e895962f59211ba1842a64f968ef91f6`, reused runtime digest `sha256:95ae1606f049770da3e44895f6be347d0bcb0226cde9c2b5f769c4e3175c960f`, Mooncake commit `1c54e233a22404692efd312739db749991d8d757`, CUDA architecture `100`, TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, and native-input digest `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`.
- The BuildKit graph selected `runtime-reuse-mooncake-and-treecore`; neither `pr-rust-builder` nor `mooncake-builder` executed. The reused production TreeCore loaded from the embedded PR source with `SGLANG_RUST_BUILD_MODE=never`.
- Layer pushes took 5.3s and 1.8s; SBOM/attestation export remained the dominant final-stage cost.

## Pre-build classification for `31a9275785295336a36961604772deccdd92a982`

- Previous candidate source: `516b449c4a6a2f5e7a1099ada6207ad4347be909`
- Candidate source: `31a9275785295336a36961604772deccdd92a982`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 516b449c4a6a2f5e7a1099ada6207ad4347be909..31a9275785295336a36961604772deccdd92a982`
- Full changed-path result: 222 paths; SHA-256 `d21d6b094d9f9db77e0f8f132d6d0df620d1bc68832bab5c92ca09c7410860b3`
- Whitespace-only equivalence: false
- Candidate archive SHA-256: `7c0bc56456fd6c144711f89d99db174c28d4d649a7bf0ef5b55efaf95eba7051`

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `false` | The exact path-limited comparison over `pr42780-native-inputs.txt` returned no paths. |
| `python_behavior_changed` | `true` | Membership observation now synchronously fences the failed slot, propagates the survivor view to tokenizer fan-out and DPC routing, and masks stale activation until matching recovery success. |
| `formatting_only` | `false` | The candidate contains behavioral and upstream changes and is not whitespace-equivalent. |

### Selected reuse path

- Reuse immutable full runtime `ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:d62346c2b91b261398c0fb203d72f97186477c03dbf6ed6eba5746630813ae78`.
- Select `runtime-reuse-mooncake-and-treecore`; neither native build graph is reachable from this target.
- Reuse TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, native-input digest `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`, produced by `516b449c4a6a2f5e7a1099ada6207ad4347be909`.
- Do not run disk reclamation or export a GHA build cache. The immutable GHCR runtime remains the cache boundary.
- Expected duration is the prior Python-only range (about 15 minutes), dominated by source download, SBOM, attestation, and OCI export rather than compilation.

### Post-build record

- Workflow run: `39815272861`
- Validation commit: `bee69dd7ce0b975fe188684a029a53a1b7d4e524`
- Result: success in 13m34s.
- Build index digest: `sha256:d1b22b69fe4e6dcb42c53ca4be4d80a1dd0bbee3050cfc1bd74c1770c3429216`
- Runnable Linux AMD64 digest: `sha256:95ae1606f049770da3e44895f6be347d0bcb0226cde9c2b5f769c4e3175c960f`
- Attestation manifest: `sha256:508d277643c452232896864e25a4d3cf7b0812e3c818f95d800d27ababdf11ba`
- Published image labels record PR revision `31a9275785295336a36961604772deccdd92a982`, reused runtime digest `sha256:d62346c2b91b261398c0fb203d72f97186477c03dbf6ed6eba5746630813ae78`, Mooncake commit `1c54e233a22404692efd312739db749991d8d757`, CUDA architecture `100`, TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, and native-input digest `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`.
- The BuildKit graph selected `runtime-reuse-mooncake-and-treecore`; neither `pr-rust-builder` nor `mooncake-builder` executed. The reused production TreeCore loaded from the embedded PR source with `SGLANG_RUST_BUILD_MODE=never`.
- SBOM/attestation export dominated the final stage; layer pushes took 3.4s and 0.6s.

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

- Workflow run: `39708245147`
- Validation commit: `caf981459e2baa461e4bdea27231450cd3457bcb`
- Result: success in 16m30s; build/push step 15m41s.
- Build index digest: `sha256:e4ab2b724bab9abc5e0c9a4716c630b90ca48bfd9bfa0ae6ea5aa0134097902a`
- Runnable Linux AMD64 digest: `sha256:d62346c2b91b261398c0fb203d72f97186477c03dbf6ed6eba5746630813ae78`
- Attestation manifest: `sha256:f4e73e04e72db8cce7f898209cab5c41edc3c07d9a40bc33f41c8bbd4edef039`
- Reused Mooncake digest: `sha256:61125246daa7194fa993b631a5012d61d7c4c79befc85f1e4e2311b57ff236a3`
- Candidate PR and TreeCore producing commit: `516b449c4a6a2f5e7a1099ada6207ad4347be909`
- New TreeCore native-input digest: `be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1`
- TreeCore artifact digest: `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`
- TreeCore rebuilt in 129.4s and loaded from the embedded candidate source with `SGLANG_RUST_BUILD_MODE=never`.
- SBOM generation took 197.2s. OCI export, attestation, and two-tag push took 151.6s; layer pushes themselves took 3.1s and 0.5s.
- The BuildKit graph selected `runtime-reuse-mooncake`; it contains `pr-rust-builder` and no `mooncake-builder` execution. There was no GHA cache export or disk reclamation.
- Published image config reports Torch `2.14.1+cu130`, Mooncake PG cache status `ready`, Mooncake source `1c54e233a22404692efd312739db749991d8d757`, base digest `sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d`, and PR revision `516b449c4a6a2f5e7a1099ada6207ad4347be909`.
