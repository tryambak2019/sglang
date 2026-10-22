# syntax=docker/dockerfile:1.7
# check=skip=InvalidBaseImagePlatform

# This validation image is intentionally Linux/AMD64-only for B200 runners.

ARG SGLANG_BASE_IMAGE=lmsysorg/sglang@sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d
ARG REUSED_MOONCAKE_IMAGE=ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:61125246daa7194fa993b631a5012d61d7c4c79befc85f1e4e2311b57ff236a3
ARG REUSED_RUNTIME_IMAGE=ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:8b908926eb3d03ddfc25b9e9116555b6602fa4ee096a450bb00724917c677bee

# Keep PR acquisition independent of the expensive Mooncake compilation. A PR
# update therefore invalidates only this small stage and the final image layer.
FROM ${SGLANG_BASE_IMAGE} AS pr-source

ARG SGLANG_PR_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG SGLANG_PR_REPOSITORY=tryambak2019/sglang
ARG SGLANG_PR_ARCHIVE_SHA256=89004aa2b1a8fd953e96e025b97851a6b104d4eae295f53d48a4f66e16c7f597

USER root
WORKDIR /opt/pr-source
RUN set -eux; \
    archive=/tmp/sglang-pr.tar.gz; \
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
      -o "${archive}" \
      "https://github.com/${SGLANG_PR_REPOSITORY}/archive/${SGLANG_PR_COMMIT}.tar.gz"; \
    echo "${SGLANG_PR_ARCHIVE_SHA256}  ${archive}" | sha256sum -c -; \
    tar -xzf "${archive}" --strip-components=1 -C /opt/pr-source; \
    printf '%s\n' "${SGLANG_PR_COMMIT}" > /opt/pr-source/.pr-head; \
    test -f python/sglang/srt/layers/moe/token_dispatcher/nixl.py

# Keep toolchain installation independent from both PR source and the declared
# native inputs so a source-only change does not repeat apt/pip setup.
FROM ${SGLANG_BASE_IMAGE} AS pr-rust-toolchain

USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential ca-certificates pkg-config; \
    rm -rf /var/lib/apt/lists/*; \
    python -m pip install --no-cache-dir 'setuptools-rust>=1.11'; \
    export PATH="/root/.cargo/bin:${PATH}"; \
    command -v cargo; \
    cargo --version; \
    rustc --version

# Build TreeCore from only its declared inputs. BuildKit hashes the selected
# COPY sources, so unrelated PR Python changes retain this stage's cache.
FROM pr-rust-toolchain AS pr-rust-builder

ARG NATIVE_ARTIFACT_SOURCE_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62

USER root
COPY validation/pr42780-native-inputs.txt /opt/pr42780-native-inputs.txt
COPY --from=pr-source /opt/pr-source/python/setup.py /opt/pr-source/python/setup.py
COPY --from=pr-source /opt/pr-source/python/pyproject.toml /opt/pr-source/python/pyproject.toml
COPY --from=pr-source /opt/pr-source/python/sglang/srt/rust_extensions/torch_build.py /opt/pr-source/python/sglang/srt/rust_extensions/torch_build.py
COPY --from=pr-source /opt/pr-source/rust/sglang-radix-tree/Cargo.toml /opt/pr-source/rust/sglang-radix-tree/Cargo.toml
COPY --from=pr-source /opt/pr-source/rust/sglang-radix-tree/Cargo.lock /opt/pr-source/rust/sglang-radix-tree/Cargo.lock
COPY --from=pr-source /opt/pr-source/rust/sglang-radix-tree/torch_compat.h /opt/pr-source/rust/sglang-radix-tree/torch_compat.h
COPY --from=pr-source /opt/pr-source/rust/sglang-radix-tree/src/*.rs /opt/pr-source/rust/sglang-radix-tree/src/
COPY --from=pr-source /opt/pr-source/rust/sglang-radix-tree/src/components/ /opt/pr-source/rust/sglang-radix-tree/src/components/

RUN set -eux; \
    export PATH="/root/.cargo/bin:${PATH}"; \
    command -v cargo; \
    cargo --version; \
    native_inputs_sha256="$(find \
      /opt/pr42780-native-inputs.txt \
      /opt/pr-source/python/setup.py \
      /opt/pr-source/python/pyproject.toml \
      /opt/pr-source/python/sglang/srt/rust_extensions/torch_build.py \
      /opt/pr-source/rust/sglang-radix-tree/Cargo.toml \
      /opt/pr-source/rust/sglang-radix-tree/Cargo.lock \
      /opt/pr-source/rust/sglang-radix-tree/torch_compat.h \
      /opt/pr-source/rust/sglang-radix-tree/src \
      -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"; \
    mkdir -p /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core; \
    printf '%s\n' \
      '[workspace]' \
      'resolver = "3"' \
      'members = []' \
      '[workspace.metadata.sglang]' \
      'extension-manifests = ["sglang-radix-tree/Cargo.toml"]' \
      > /opt/pr-source/rust/Cargo.toml; \
    cd /opt/pr-source/python; \
    SGLANG_BUILD_RUST_EXTS=mem_cache python setup.py build_rust --inplace; \
    extension_count="$(find sglang/srt/mem_cache/rust_tree_core -maxdepth 1 -type f -name 'mem_cache.*.so' | wc -l)"; \
    test "${extension_count}" -eq 1; \
    extension="$(find sglang/srt/mem_cache/rust_tree_core -maxdepth 1 -type f -name 'mem_cache.*.so' -print -quit)"; \
    test -n "${extension}"; \
    mkdir -p /opt/pr-rust-artifact; \
    cp --preserve=mode,timestamps "${extension}" /opt/pr-rust-artifact/; \
    artifact_sha256="$(sha256sum "${extension}" | cut -d' ' -f1)"; \
    printf 'source_revision=%s\nartifact_sha256=%s\nnative_inputs_sha256=%s\n' \
      "${NATIVE_ARTIFACT_SOURCE_COMMIT}" "${artifact_sha256}" "${native_inputs_sha256}" \
      > /opt/pr-rust-artifact/build-metadata.env

# Build against the exact SGLang runtime, not merely the same nominal
# Torch/CUDA versions. This makes the compiled PG adapter ABI-specific to the
# image that will run the recovery validation.
FROM ${SGLANG_BASE_IMAGE} AS mooncake-builder

ARG MOONCAKE_REPOSITORY=https://github.com/kvcache-ai/Mooncake.git
ARG MOONCAKE_BUILD_COMMIT=1c54e233a22404692efd312739db749991d8d757
ARG CUDA_ARCHITECTURE=100

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    MAX_JOBS=2 \
    PATH="/usr/local/go/bin:${PATH}"

USER root
WORKDIR /opt/mooncake-src

COPY validation/mooncake-sm100.patch /tmp/mooncake-sm100.patch

RUN set -eux; \
    cuda_arch_major="${CUDA_ARCHITECTURE%?}"; \
    export TORCH_CUDA_ARCH_LIST="${cuda_arch_major}.${CUDA_ARCHITECTURE#${cuda_arch_major}}"; \
    export CUDAARCHS="${CUDA_ARCHITECTURE}-real"; \
    command -v nvcc; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__; print(torch.__version__, torch.version.cuda)'; \
    git clone --filter=blob:none --no-checkout "${MOONCAKE_REPOSITORY}" .; \
    git fetch --depth=1 origin "${MOONCAKE_BUILD_COMMIT}"; \
    git checkout --detach "${MOONCAKE_BUILD_COMMIT}"; \
    test "$(git rev-parse HEAD)" = "${MOONCAKE_BUILD_COMMIT}"; \
    git apply --check /tmp/mooncake-sm100.patch; \
    git apply /tmp/mooncake-sm100.patch; \
    bash dependencies.sh -y

RUN set -eux; \
    cuda_arch_major="${CUDA_ARCHITECTURE%?}"; \
    export TORCH_CUDA_ARCH_LIST="${cuda_arch_major}.${CUDA_ARCHITECTURE#${cuda_arch_major}}"; \
    export CUDAARCHS="${CUDA_ARCHITECTURE}-real"; \
    mkdir -p build; \
    cd build; \
    cmake -G Ninja .. \
      -DBUILD_UNIT_TESTS=OFF \
      -DUSE_HTTP=ON \
      -DUSE_ETCD=ON \
      -DUSE_CUDA=ON \
      -DWITH_EP=ON \
      -DSTORE_USE_ETCD=ON \
      -DPython3_EXECUTABLE=/opt/sglang/bin/python \
      -DCMAKE_CUDA_ARCHITECTURES="${CUDAARCHS}" \
      -DCMAKE_BUILD_TYPE=Release; \
    export LIBRARY_PATH="/usr/local/cuda/lib64/stubs:${LIBRARY_PATH:-}"; \
    cmake --build . --parallel 2; \
    cd /opt/mooncake-src; \
    export PATH="/usr/local/nvidia/bin:/usr/local/nvidia/lib64:${PATH}"; \
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH:-}"; \
    export LIBRARY_PATH="/usr/local/cuda/lib64/stubs:${LIBRARY_PATH:-}"; \
    mkdir -p build/mooncake-transfer-engine/nvlink-allocator; \
    cd mooncake-transfer-engine/nvlink-allocator; \
    bash build.sh ../../build/mooncake-transfer-engine/nvlink-allocator/; \
    cd /opt/mooncake-src; \
    PYTHON_VERSION=3.12 OUTPUT_DIR=dist ./scripts/build_wheel.sh; \
    python -m pip install --no-cache-dir mooncake-wheel/dist/*.whl; \
    ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1; \
    python -m mooncake.pg --prebuild; \
    test -d /root/.cache/mooncake/pg_jit

# Preserve the official SGLang image byte-for-byte except for replacing the
# Mooncake Python distribution, copying its matching PG cache, and recording
# immutable provenance metadata.
FROM ${SGLANG_BASE_IMAGE} AS runtime-rebuild-mooncake

ARG MOONCAKE_BUILD_COMMIT=1c54e233a22404692efd312739db749991d8d757
ARG SGLANG_BASE_IMAGE_DIGEST=sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d
ARG SGLANG_PR_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG NATIVE_ARTIFACT_SOURCE_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG CUDA_ARCHITECTURE=100

ENV MOONCAKE_BUILD_COMMIT=${MOONCAKE_BUILD_COMMIT} \
    SGLANG_BASE_IMAGE_DIGEST=${SGLANG_BASE_IMAGE_DIGEST} \
    SGLANG_PR_COMMIT=${SGLANG_PR_COMMIT} \
    SGLANG_NATIVE_ARTIFACT_SOURCE_COMMIT=${NATIVE_ARTIFACT_SOURCE_COMMIT} \
    PYTHONPATH=/opt/pr-source/python

LABEL org.opencontainers.image.title="SGLang PR 42780 Mooncake validation dependency" \
      org.opencontainers.image.description="Official SGLang base with pinned Mooncake and PR 42780 source for fixed-slot recovery validation" \
      org.opencontainers.image.base.digest=${SGLANG_BASE_IMAGE_DIGEST} \
      org.opencontainers.image.revision=${SGLANG_PR_COMMIT} \
      ai.mooncake.source.revision=${MOONCAKE_BUILD_COMMIT} \
      ai.sglang.native-artifact.source.revision=${NATIVE_ARTIFACT_SOURCE_COMMIT} \
      ai.mooncake.cuda.architecture=${CUDA_ARCHITECTURE} \
      org.opencontainers.image.source="https://github.com/tryambak2019/sglang"

USER root
COPY --from=mooncake-builder /opt/mooncake-src/mooncake-wheel/dist/ /tmp/mooncake-wheel/
COPY --from=mooncake-builder /root/.cache/mooncake/pg_jit/ /root/.cache/mooncake/pg_jit/
COPY --from=pr-source /opt/pr-source/ /opt/pr-source/
COPY --from=pr-rust-builder /opt/pr-rust-artifact/ /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/

RUN set -eux; \
    python -m pip uninstall -y mooncake-transfer-engine mooncake-transfer-engine-cuda13 || true; \
    python -m pip install --no-cache-dir --no-deps /tmp/mooncake-wheel/*.whl; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__'; \
    python -m mooncake.pg --report; \
    test "$(cat /opt/pr-source/.pr-head)" = "${SGLANG_PR_COMMIT}"; \
    cat /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/build-metadata.env; \
    python -c 'import pathlib, sglang; p=pathlib.Path(sglang.__file__).resolve(); assert str(p).startswith("/opt/pr-source/python/"), p; print(p)'; \
    test -n "${MOONCAKE_BUILD_COMMIT}"; \
    test -n "${SGLANG_BASE_IMAGE_DIGEST}"

RUN PYTHONPATH=/opt/pr-source/python SGLANG_RUST_BUILD_MODE=never python - <<'PY'
from pathlib import Path

from sglang.srt.mem_cache.rust_tree_core.extension import bindings

module_path = Path(bindings.__file__).resolve()
expected_root = Path("/opt/pr-source/python").resolve()
if expected_root not in module_path.parents:
    raise SystemExit(f"Rust TreeCore was not loaded from embedded PR source: {module_path}")
binding = bindings.RustUnifiedTreeCoreBinding
for method in ("adjust_component_size", "collect_path_info"):
    if not hasattr(binding, method):
        raise SystemExit(f"RustUnifiedTreeCoreBinding is missing {method}")
print(f"loaded production Rust TreeCore from {module_path}")
PY

# Reuse the previously published immutable Mooncake runtime when the recorded
# four-way classification proves that every Mooncake input is unchanged. This
# target deliberately has no dependency edge to mooncake-builder, so BuildKit
# neither downloads nor re-exports that large build graph through the GHA cache.
FROM ${REUSED_MOONCAKE_IMAGE} AS runtime-reuse-mooncake

ARG REUSED_MOONCAKE_IMAGE=ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:61125246daa7194fa993b631a5012d61d7c4c79befc85f1e4e2311b57ff236a3
ARG REUSED_MOONCAKE_IMAGE_DIGEST=sha256:61125246daa7194fa993b631a5012d61d7c4c79befc85f1e4e2311b57ff236a3
ARG MOONCAKE_BUILD_COMMIT=1c54e233a22404692efd312739db749991d8d757
ARG SGLANG_BASE_IMAGE_DIGEST=sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d
ARG SGLANG_PR_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG NATIVE_ARTIFACT_SOURCE_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG CUDA_ARCHITECTURE=100

ENV MOONCAKE_BUILD_COMMIT=${MOONCAKE_BUILD_COMMIT} \
    SGLANG_BASE_IMAGE_DIGEST=${SGLANG_BASE_IMAGE_DIGEST} \
    SGLANG_PR_COMMIT=${SGLANG_PR_COMMIT} \
    SGLANG_NATIVE_ARTIFACT_SOURCE_COMMIT=${NATIVE_ARTIFACT_SOURCE_COMMIT} \
    SGLANG_REUSED_MOONCAKE_IMAGE_DIGEST=${REUSED_MOONCAKE_IMAGE_DIGEST} \
    PYTHONPATH=/opt/pr-source/python

LABEL org.opencontainers.image.title="SGLang PR 42780 Mooncake validation dependency" \
      org.opencontainers.image.description="Pinned Mooncake dependency image overlaid with PR 42780 source for fixed-slot recovery validation" \
      org.opencontainers.image.base.digest=${SGLANG_BASE_IMAGE_DIGEST} \
      org.opencontainers.image.revision=${SGLANG_PR_COMMIT} \
      ai.mooncake.source.revision=${MOONCAKE_BUILD_COMMIT} \
      ai.mooncake.dependency.image=${REUSED_MOONCAKE_IMAGE} \
      ai.mooncake.dependency.digest=${REUSED_MOONCAKE_IMAGE_DIGEST} \
      ai.sglang.native-artifact.source.revision=${NATIVE_ARTIFACT_SOURCE_COMMIT} \
      ai.mooncake.cuda.architecture=${CUDA_ARCHITECTURE} \
      org.opencontainers.image.source="https://github.com/tryambak2019/sglang"

USER root
RUN rm -rf /opt/pr-source
COPY --from=pr-source /opt/pr-source/ /opt/pr-source/
COPY --from=pr-rust-builder /opt/pr-rust-artifact/ /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/

RUN set -eux; \
    test "$(cat /opt/pr-source/.pr-head)" = "${SGLANG_PR_COMMIT}"; \
    test "${REUSED_MOONCAKE_IMAGE}" = "ghcr.io/tryambak2019/sglang-pr42780-recovery@${REUSED_MOONCAKE_IMAGE_DIGEST}"; \
    test "${MOONCAKE_BUILD_COMMIT}" = "1c54e233a22404692efd312739db749991d8d757"; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__'; \
    python -m mooncake.pg --report; \
    cat /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/build-metadata.env; \
    python -c 'import pathlib, sglang; p=pathlib.Path(sglang.__file__).resolve(); assert str(p).startswith("/opt/pr-source/python/"), p; print(p)'

RUN PYTHONPATH=/opt/pr-source/python SGLANG_RUST_BUILD_MODE=never python - <<'PY'
from pathlib import Path

from sglang.srt.mem_cache.rust_tree_core.extension import bindings

module_path = Path(bindings.__file__).resolve()
expected_root = Path("/opt/pr-source/python").resolve()
if expected_root not in module_path.parents:
    raise SystemExit(f"Rust TreeCore was not loaded from embedded PR source: {module_path}")
binding = bindings.RustUnifiedTreeCoreBinding
for method in ("adjust_component_size", "collect_path_info"):
    if not hasattr(binding, method):
        raise SystemExit(f"RustUnifiedTreeCoreBinding is missing {method}")
print(f"loaded production Rust TreeCore from {module_path}")
PY

# Python-only candidates reuse both Mooncake and TreeCore from the last
# verified runtime. The two source stages share the same immutable registry
# base, while the final stage deletes the old PR tree before overlaying the new
# archive. No Mooncake or Rust builder is reachable from this target.
FROM ${REUSED_RUNTIME_IMAGE} AS pr-source-reuse-runtime

ARG SGLANG_PR_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG SGLANG_PR_REPOSITORY=tryambak2019/sglang
ARG SGLANG_PR_ARCHIVE_SHA256=89004aa2b1a8fd953e96e025b97851a6b104d4eae295f53d48a4f66e16c7f597

USER root
RUN set -eux; \
    rm -rf /opt/pr-source; \
    mkdir -p /opt/pr-source; \
    archive=/tmp/sglang-pr.tar.gz; \
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
      -o "${archive}" \
      "https://github.com/${SGLANG_PR_REPOSITORY}/archive/${SGLANG_PR_COMMIT}.tar.gz"; \
    echo "${SGLANG_PR_ARCHIVE_SHA256}  ${archive}" | sha256sum -c -; \
    tar -xzf "${archive}" --strip-components=1 -C /opt/pr-source; \
    printf '%s\n' "${SGLANG_PR_COMMIT}" > /opt/pr-source/.pr-head; \
    test -f /opt/pr-source/python/sglang/srt/layers/moe/token_dispatcher/nixl.py

FROM ${REUSED_RUNTIME_IMAGE} AS reused-runtime-artifacts

FROM ${REUSED_RUNTIME_IMAGE} AS runtime-reuse-mooncake-and-treecore

ARG REUSED_RUNTIME_IMAGE=ghcr.io/tryambak2019/sglang-pr42780-recovery@sha256:8b908926eb3d03ddfc25b9e9116555b6602fa4ee096a450bb00724917c677bee
ARG REUSED_RUNTIME_IMAGE_DIGEST=sha256:8b908926eb3d03ddfc25b9e9116555b6602fa4ee096a450bb00724917c677bee
ARG MOONCAKE_BUILD_COMMIT=1c54e233a22404692efd312739db749991d8d757
ARG SGLANG_BASE_IMAGE_DIGEST=sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d
ARG SGLANG_PR_COMMIT=e658396f16f112cfd5daeea3a3fd444335930a62
ARG NATIVE_ARTIFACT_SOURCE_COMMIT=516b449c4a6a2f5e7a1099ada6207ad4347be909
ARG NATIVE_ARTIFACT_SHA256=21f2f46c2cf958139b6ea52746da84bfb43cd535850a9073336cf773aa3f981c
ARG NATIVE_INPUTS_SHA256=be7b35636f853e8917c2c5185bc04b6737d1d84c1b3eaddc6c4be84d6cda93f1
ARG CUDA_ARCHITECTURE=100

ENV MOONCAKE_BUILD_COMMIT=${MOONCAKE_BUILD_COMMIT} \
    SGLANG_BASE_IMAGE_DIGEST=${SGLANG_BASE_IMAGE_DIGEST} \
    SGLANG_PR_COMMIT=${SGLANG_PR_COMMIT} \
    SGLANG_NATIVE_ARTIFACT_SOURCE_COMMIT=${NATIVE_ARTIFACT_SOURCE_COMMIT} \
    SGLANG_REUSED_RUNTIME_IMAGE_DIGEST=${REUSED_RUNTIME_IMAGE_DIGEST} \
    PYTHONPATH=/opt/pr-source/python

LABEL org.opencontainers.image.title="SGLang PR 42780 Mooncake validation dependency" \
      org.opencontainers.image.description="Pinned Mooncake and TreeCore runtime overlaid with Python-only PR 42780 source" \
      org.opencontainers.image.base.digest=${SGLANG_BASE_IMAGE_DIGEST} \
      org.opencontainers.image.revision=${SGLANG_PR_COMMIT} \
      ai.mooncake.source.revision=${MOONCAKE_BUILD_COMMIT} \
      ai.sglang.reused-runtime.image=${REUSED_RUNTIME_IMAGE} \
      ai.sglang.reused-runtime.digest=${REUSED_RUNTIME_IMAGE_DIGEST} \
      ai.sglang.native-artifact.source.revision=${NATIVE_ARTIFACT_SOURCE_COMMIT} \
      ai.sglang.native-artifact.digest=${NATIVE_ARTIFACT_SHA256} \
      ai.sglang.native-inputs.digest=${NATIVE_INPUTS_SHA256} \
      ai.mooncake.cuda.architecture=${CUDA_ARCHITECTURE} \
      org.opencontainers.image.source="https://github.com/tryambak2019/sglang"

USER root
RUN rm -rf /opt/pr-source
COPY --from=pr-source-reuse-runtime /opt/pr-source/ /opt/pr-source/
COPY --from=reused-runtime-artifacts /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/mem_cache.*.so /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/
COPY --from=reused-runtime-artifacts /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/build-metadata.env /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/build-metadata.env

RUN set -eux; \
    test "$(cat /opt/pr-source/.pr-head)" = "${SGLANG_PR_COMMIT}"; \
    test "${REUSED_RUNTIME_IMAGE}" = "ghcr.io/tryambak2019/sglang-pr42780-recovery@${REUSED_RUNTIME_IMAGE_DIGEST}"; \
    test "${MOONCAKE_BUILD_COMMIT}" = "1c54e233a22404692efd312739db749991d8d757"; \
    metadata=/opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core/build-metadata.env; \
    extension="$(find /opt/pr-source/python/sglang/srt/mem_cache/rust_tree_core -maxdepth 1 -type f -name 'mem_cache.*.so' -print -quit)"; \
    test -n "${extension}"; \
    echo "${NATIVE_ARTIFACT_SHA256}  ${extension}" | sha256sum -c -; \
    grep -Fx "source_revision=${NATIVE_ARTIFACT_SOURCE_COMMIT}" "${metadata}"; \
    grep -Fx "artifact_sha256=${NATIVE_ARTIFACT_SHA256}" "${metadata}"; \
    grep -Fx "native_inputs_sha256=${NATIVE_INPUTS_SHA256}" "${metadata}"; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__'; \
    python -m mooncake.pg --report; \
    cat "${metadata}"; \
    python -c 'import pathlib, sglang; p=pathlib.Path(sglang.__file__).resolve(); assert str(p).startswith("/opt/pr-source/python/"), p; print(p)'

RUN PYTHONPATH=/opt/pr-source/python SGLANG_RUST_BUILD_MODE=never python - <<'PY'
from pathlib import Path

from sglang.srt.mem_cache.rust_tree_core.extension import bindings

module_path = Path(bindings.__file__).resolve()
expected_root = Path("/opt/pr-source/python").resolve()
if expected_root not in module_path.parents:
    raise SystemExit(f"Rust TreeCore was not loaded from embedded PR source: {module_path}")
binding = bindings.RustUnifiedTreeCoreBinding
for method in ("adjust_component_size", "collect_path_info"):
    if not hasattr(binding, method):
        raise SystemExit(f"RustUnifiedTreeCoreBinding is missing {method}")
print(f"loaded reused production Rust TreeCore from {module_path}")
PY
