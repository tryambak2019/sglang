# PR 42780 build-reuse record

## Pre-build classification for `162593a1ba5c6b8227cc3f0678489069f7b65c3b`

- Previous embedded source: `2b035c7502102dc89c962c75417262809f2cf126`
- Candidate source: `162593a1ba5c6b8227cc3f0678489069f7b65c3b`
- Target: Linux AMD64, B200/SM100, CUDA architecture `100-real`
- Full changed-path command: `git diff --name-only 2b035c7502102dc89c962c75417262809f2cf126..162593a1ba5c6b8227cc3f0678489069f7b65c3b`
- Full changed-path result: 1,385 paths; SHA-256 `4fd97578fe169456a440dcf0f1c7922c33676fb783716b5a850f3aa34f50aa4f`
- Whitespace-only equivalence: false (`git diff -w --quiet` exited 1)

| Classification | Value | Evidence |
| --- | --- | --- |
| `mooncake_inputs_changed` | `false` | Mooncake commit, SM100 patch, CUDA architecture, base-image digest, Torch/CUDA ABI, builder commands, and PG inputs are unchanged. |
| `native_inputs_changed` | `true` | `python/pyproject.toml` and production files under `rust/sglang-radix-tree/src/` changed during the upstream rebase. |
| `python_behavior_changed` | `true` | The candidate adds membership-observation routing, timeout diagnostics, and route-level tests. |
| `formatting_only` | `false` | The candidate contains behavioral changes and is not whitespace-equivalent. |

### Intended reuse

- Mooncake builder: reuse the GitHub Actions cache; rebuild only on a cache miss.
- TreeCore native artifact: rebuild for this candidate because native inputs changed.
- Runtime image: rebuild with the complete candidate PR source and new immutable provenance.
- Future Python-only candidates: reuse the TreeCore stage by copying only the inputs declared in `pr42780-native-inputs.txt`.

### Declared heavy-stage inputs

- Mooncake: base-image digest, Mooncake commit, `mooncake-sm100.patch`, CUDA architecture, Torch/CUDA ABI, dependency/build commands, and PG prebuild command.
- TreeCore: base-image/Python/Torch/compiler ABI, `pr42780-native-inputs.txt`, the files it names, the Rust build command, and `NATIVE_ARTIFACT_SOURCE_COMMIT`.

## Post-build record

Pending workflow completion. Record the workflow SHA, index and AMD64 digests, Mooncake commit, TreeCore artifact and input digests, producing source SHA, observed cache hits or misses, and any divergence from the plan above.
