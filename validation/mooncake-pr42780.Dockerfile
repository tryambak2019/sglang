# syntax=docker/dockerfile:1.7

ARG SGLANG_BASE_IMAGE=lmsysorg/sglang@sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d

# Keep PR acquisition independent of the expensive Mooncake compilation. A PR
# update therefore invalidates only this small stage and the final image layer.
FROM ${SGLANG_BASE_IMAGE} AS pr-source

ARG SGLANG_PR_COMMIT=f481ab6a87c4c4aea4ac38f040b051a0ee4da8ae
ARG SGLANG_PR_REPOSITORY=tryambak2019/sglang
ARG SGLANG_PR_ARCHIVE_SHA256=f759ca8c22ea98b00cf31e6d146861f59a62544578442e5f19a96844c127ed85

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

# Build the TreeCore binding from the embedded PR checkout. The extension must
# match the PR Python API, rather than the base image's possibly older ABI.
FROM ${SGLANG_BASE_IMAGE} AS pr-rust-builder

USER root
COPY --from=pr-source /opt/pr-source/ /opt/pr-source/

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential ca-certificates pkg-config; \
    rm -rf /var/lib/apt/lists/*; \
    python -m pip install --no-cache-dir 'setuptools-rust>=1.11'; \
    export PATH="/root/.cargo/bin:${PATH}"; \
    command -v cargo; \
    cargo --version; \
    rustc --version; \
    test -f /opt/pr-source/rust/Cargo.lock; \
    test -f /opt/pr-source/rust/sglang-radix-tree/Cargo.lock

RUN set -eux; \
    export PATH="/root/.cargo/bin:${PATH}"; \
    command -v cargo; \
    cargo --version; \
    cd /opt/pr-source/python; \
    SGLANG_BUILD_RUST_EXTS=mem_cache python setup.py build_rust --inplace; \
    extension_count="$(find sglang/srt/mem_cache/rust_tree_core -maxdepth 1 -type f -name 'mem_cache.*.so' | wc -l)"; \
    test "${extension_count}" -eq 1; \
    extension="$(find sglang/srt/mem_cache/rust_tree_core -maxdepth 1 -type f -name 'mem_cache.*.so' -print -quit)"; \
    test -n "${extension}"; \
    mkdir -p /opt/pr-rust-artifact; \
    cp --preserve=mode,timestamps "${extension}" /opt/pr-rust-artifact/

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
FROM ${SGLANG_BASE_IMAGE} AS runtime

ARG MOONCAKE_BUILD_COMMIT=1c54e233a22404692efd312739db749991d8d757
ARG SGLANG_BASE_IMAGE_DIGEST=sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d
ARG SGLANG_PR_COMMIT=f481ab6a87c4c4aea4ac38f040b051a0ee4da8ae
ARG CUDA_ARCHITECTURE=100

ENV MOONCAKE_BUILD_COMMIT=${MOONCAKE_BUILD_COMMIT} \
    SGLANG_BASE_IMAGE_DIGEST=${SGLANG_BASE_IMAGE_DIGEST} \
    SGLANG_PR_COMMIT=${SGLANG_PR_COMMIT} \
    PYTHONPATH=/opt/pr-source/python

LABEL org.opencontainers.image.title="SGLang PR 42780 Mooncake validation dependency" \
      org.opencontainers.image.description="Official SGLang base with pinned Mooncake and PR 42780 source for fixed-slot recovery validation" \
      org.opencontainers.image.base.digest=${SGLANG_BASE_IMAGE_DIGEST} \
      org.opencontainers.image.revision=${SGLANG_PR_COMMIT} \
      ai.mooncake.source.revision=${MOONCAKE_BUILD_COMMIT} \
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
