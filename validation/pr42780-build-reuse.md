# PR 42780 build-reuse record

## Pre-build classification for `6c40dbfec2103245abbab0721265efa747ed72c5`

- Previous candidate source: `162593a1ba5c6b8227cc3f0678489069f7b65c3b`
- Candidate source: `6c40dbfec2103245abbab0721265efa747ed72c5`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 162593a1ba5c6b8227cc3f0678489069f7b65c3b..6c40dbfec2103245abbab0721265efa747ed72c5`
- Full changed-path result: 5 paths; SHA-256 `f6abc0169bf873355142df6254fba1c9c8614fe97fd3a20894dc9dfe71a6098b`
- Whitespace-only equivalence: false (`git diff -w --quiet` exited 1)
- Candidate archive SHA-256: `776568d15fc61182921d1c0934f1059a1f4ba272e8a2d32572e80d251e88d2e2`

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `false` | A path-limited `git diff --quiet` over every input declared in `pr42780-native-inputs.txt` exited 0 between the previous and corrected candidate. |
| `python_behavior_changed` | `true` | The candidate corrects cross-path progress reporting and replaces mocked transport with a real in-process ZMQ route regression. |
| `formatting_only` | `false` | The candidate contains behavioral changes and is not whitespace-equivalent. |

### Selected reuse path

- Canceled workflow run `39655586156` because it embedded obsolete source `162593a1ba...`; its output must not be dispatched.
- Reuse immutable Mooncake dependency image `ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:61125246daa7194fa993b631a5012d61d7c4c79befc85f1e4e2311b57ff236a3`.
- Select `runtime-reuse-mooncake`; `mooncake-builder` is not in that target's dependency graph.
- Delete the dependency image's old `/opt/pr-source` before copying the complete corrected archive, preventing deleted files from surviving the overlay.
- Build TreeCore once for the corrected source because the canceled run did not publish a reusable AMD64 artifact. The native-input equivalence proof explains why the generated artifact should be behaviorally identical to the canceled candidate's artifact.
- Scope the GHA cache to `pr42780-rust-treecore-v1`. The selected graph contains the PR acquisition, Rust toolchain, TreeCore builder, and final overlay, but excludes the Mooncake source/build graph.
- Retain disk reclamation for this first measured reuse run. Revisit it only after recording available runner disk and total step time.

### Declared heavy-stage inputs

- Mooncake: base-image digest, Mooncake commit, `mooncake-sm100.patch`, CUDA architecture, Torch/CUDA ABI, dependency/build commands, and PG prebuild command.
- TreeCore: base-image/Python/Torch/compiler ABI, `pr42780-native-inputs.txt`, the files it names, the Rust build command, and `NATIVE_ARTIFACT_SOURCE_COMMIT`.

## Post-build record

Pending replacement workflow completion. Record the workflow SHA, index and AMD64 digests, reused dependency-image digest, Mooncake commit, TreeCore artifact and input digests, producing source SHA, observed cache hits or misses, cache transfer/export duration, disk-reclamation duration, and any divergence from the plan above.
