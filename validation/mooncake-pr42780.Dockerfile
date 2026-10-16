# syntax=docker/dockerfile:1.7

ARG SGLANG_BASE_IMAGE=lmsysorg/sglang@sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d

# Keep PR acquisition independent of the expensive Mooncake compilation. A PR
# update therefore invalidates only this small stage and the final image layer.
FROM ${SGLANG_BASE_IMAGE} AS pr-source

ARG SGLANG_PR_COMMIT=a73ca55f23bff0a3078da00f897d41e9b843f491
ARG SGLANG_PR_ARCHIVE_SHA256=48581d1cd796dc353aaa39ba23b12b9f7229d0ccf478583f60d5f6288506e931

USER root
WORKDIR /opt/pr-source
RUN set -eux; \
    archive=/tmp/sglang-pr.tar.gz; \
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
      -o "${archive}" \
      "https://github.com/sgl-project/sglang/archive/${SGLANG_PR_COMMIT}.tar.gz"; \
    echo "${SGLANG_PR_ARCHIVE_SHA256}  ${archive}" | sha256sum -c -; \
    tar -xzf "${archive}" --strip-components=1 -C /opt/pr-source; \
    printf '%s\n' "${SGLANG_PR_COMMIT}" > /opt/pr-source/.pr-head; \
    test -f python/sglang/srt/layers/moe/token_dispatcher/nixl.py

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
ARG SGLANG_PR_COMMIT=a73ca55f23bff0a3078da00f897d41e9b843f491

ENV MOONCAKE_BUILD_COMMIT=${MOONCAKE_BUILD_COMMIT} \
    SGLANG_BASE_IMAGE_DIGEST=${SGLANG_BASE_IMAGE_DIGEST} \
    SGLANG_PR_COMMIT=${SGLANG_PR_COMMIT} \
    PYTHONPATH=/opt/pr-source/python

LABEL org.opencontainers.image.title="SGLang PR 42780 Mooncake validation dependency" \
      org.opencontainers.image.description="Official SGLang base with pinned Mooncake and PR 42780 source for fixed-slot recovery validation" \
      org.opencontainers.image.base.digest=${SGLANG_BASE_IMAGE_DIGEST} \
      org.opencontainers.image.revision=${SGLANG_PR_COMMIT} \
      ai.mooncake.source.revision=${MOONCAKE_BUILD_COMMIT} \
      org.opencontainers.image.source="https://github.com/tryambak2019/sglang"

USER root
COPY --from=mooncake-builder /opt/mooncake-src/mooncake-wheel/dist/ /tmp/mooncake-wheel/
COPY --from=mooncake-builder /root/.cache/mooncake/pg_jit/ /root/.cache/mooncake/pg_jit/
COPY --from=pr-source /opt/pr-source/ /opt/pr-source/

RUN set -eux; \
    python -m pip uninstall -y mooncake-transfer-engine mooncake-transfer-engine-cuda13 || true; \
    python -m pip install --no-cache-dir --no-deps /tmp/mooncake-wheel/*.whl; \
    python -c 'import torch; assert torch.__version__.split("+")[0] == "2.14.1", torch.__version__'; \
    python -m mooncake.pg --report; \
    test "$(cat /opt/pr-source/.pr-head)" = "${SGLANG_PR_COMMIT}"; \
    python -c 'import pathlib, sglang; p=pathlib.Path(sglang.__file__).resolve(); assert str(p).startswith("/opt/pr-source/python/"), p; print(p)'; \
    test -n "${MOONCAKE_BUILD_COMMIT}"; \
    test -n "${SGLANG_BASE_IMAGE_DIGEST}"

