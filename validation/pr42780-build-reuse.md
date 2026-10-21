# PR 42780 build-reuse record

## Pre-build classification for `06d70f151668a69af64c2e6f2004ed8aa7d062fd`

- Previous candidate source: `6c40dbfec2103245abbab0721265efa747ed72c5`
- Candidate source: `06d70f151668a69af64c2e6f2004ed8aa7d062fd`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 6c40dbfec2103245abbab0721265efa747ed72c5..06d70f151668a69af64c2e6f2004ed8aa7d062fd`
- Full changed-path result: 7 paths; SHA-256 `5087b14e6965219d3a979fe1a7afa84608184980da446035ce13e51e72817f81`
- Whitespace-only equivalence: false (`git diff -w --quiet` exited 1)
- Candidate archive SHA-256: `e4539319c79185cafa2e454c63a0e72db7d48b4702cd8205ac00106171e32393`

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `false` | A path-limited `git diff --quiet` over every input declared in `pr42780-native-inputs.txt` exited 0. The prior artifact records native-input digest `05e71eb6f5bac4e9103172f93ba8cfe676ab5a74ea5cbee16910936f1fbb4c9b`. |
| `python_behavior_changed` | `true` | The candidate adds a bounded membership deadline, correlated rejection before expired mutation, and delayed-acknowledgement regressions. |
| `formatting_only` | `false` | The candidate contains behavioral changes and is not whitespace-equivalent. |

### Selected reuse path

- Reuse immutable runtime `ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:6b3447e447aa26dc4c2caa309ef47ad03507b6cd9a694ccb171fb34b82c815a5`.
- That runtime contains Mooncake commit `1c54e233a22404692efd312739db749991d8d757` and TreeCore artifact `21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c`, produced from source `6c40dbfec2103245abbab0721265efa747ed72c5` and native-input digest `05e71eb6f5bac4e9103172f93ba8cfe676ab5a74ea5cbee16910936f1fbb4c9b`.
- Select `runtime-reuse-mooncake-and-treecore`. Neither `mooncake-builder` nor `pr-rust-builder` is in its dependency graph.
- Delete the reused runtime's old `/opt/pr-source` before copying the complete candidate archive. Copy back only the verified TreeCore shared object and its build metadata from the immutable runtime.
- Do not use a GHA cache on this Python-only path. The immutable GHCR runtime is the cache boundary, and cache export was the previous run's dominant cost.
- Remove disk reclamation for this lightweight path. The measured prior run proved the reused runtime pull took only about 17 seconds and the selected graph no longer needs compiler or Mooncake build scratch space.

### Prior measured run `39662991959`

- Validation commit: `db68e149056dd4ad746b775af02cbc2f8ccbbf69`
- Build index digest: `sha256:4ce3347dc40b5fabbd6a5c89e5eed20ede8fac0fb231865e59a05c4e750f729c`
- Runnable AMD64 digest: `sha256:6b3447e447aa26dc4c2caa309ef47ad03507b6cd9a694ccb171fb34b82c815a5`
- Disk reclamation: 4m15s.
- TreeCore compile: 82.7s.
- Reused runtime pull: about 17s.
- Build/push action: 39m04s.
- GHA `mode=max` cache export: 1,524.4s (25m24s), the dominant remaining cost.
- Total job: about 44m38s. This did not meet the intended small-overlay build time, so the next path removes both the Rust build and GHA cache export.

## Post-build record

Pending workflow completion. Record the workflow SHA, index and AMD64 digests, reused runtime digest, candidate PR SHA, Mooncake commit, TreeCore artifact/input digests and producing SHA, observed registry transfer/export duration, total build duration, and any divergence from the plan above.
