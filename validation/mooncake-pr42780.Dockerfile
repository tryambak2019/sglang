# syntax=docker/dockerfile:1.7

ARG SGLANG_BASE_IMAGE=lmsysorg/sglang@sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d

# Build against the exact SGLang runtime, not merely the same nominal
# Torch/CUDA versions. This makes the compiled PG adapter ABI-specific to the
# image that will run the recovery validation.
FROM ${SGLANG_BASE_IMAGE} AS mooncake-builder

ARG MOONCAKE_REPOSITORY=https://github.com/kvcache-ai/Mooncake.git
ARG MOONCAKE_BUILD_COMMIT=1c54e233a22404692efd312739db749991d8d757
ARG TORCH_CUDA_ARCH_LIST="8.0;9.0;10.0;10.3"

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    MAX_JOBS=2 \
    PATH="/usr/local/go/bin:${PATH}"

USER root
WORKDIR /opt/mooncake-src

RUN set -eux; \
    command -v nvcc; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__; print(torch.__version__, torch.version.cuda)'; \
    git clone --filter=blob:none --no-checkout "${MOONCAKE_REPOSITORY}" .; \
    git fetch --depth=1 origin "${MOONCAKE_BUILD_COMMIT}"; \
    git checkout --detach "${MOONCAKE_BUILD_COMMIT}"; \
    test "$(git rev-parse HEAD)" = "${MOONCAKE_BUILD_COMMIT}"; \
    bash dependencies.sh -y

RUN set -eux; \
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

ENV MOONCAKE_BUILD_COMMIT=${MOONCAKE_BUILD_COMMIT} \
    SGLANG_BASE_IMAGE_DIGEST=${SGLANG_BASE_IMAGE_DIGEST}

LABEL org.opencontainers.image.title="SGLang PR 42780 Mooncake validation dependency" \
      org.opencontainers.image.description="Official SGLang image with only Mooncake replaced for fixed-slot recovery validation" \
      org.opencontainers.image.base.digest=${SGLANG_BASE_IMAGE_DIGEST} \
      org.opencontainers.image.revision=${MOONCAKE_BUILD_COMMIT} \
      org.opencontainers.image.source="https://github.com/tryambak2019/sglang"

USER root
COPY --from=mooncake-builder /opt/mooncake-src/mooncake-wheel/dist/ /tmp/mooncake-wheel/
COPY --from=mooncake-builder /root/.cache/mooncake/pg_jit/ /root/.cache/mooncake/pg_jit/

RUN set -eux; \
    python -m pip uninstall -y mooncake-transfer-engine mooncake-transfer-engine-cuda13 || true; \
    python -m pip install --no-cache-dir --no-deps /tmp/mooncake-wheel/*.whl; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__'; \
    python -m mooncake.pg --report; \
    test -n "${MOONCAKE_BUILD_COMMIT}"; \
    test -n "${SGLANG_BASE_IMAGE_DIGEST}"

