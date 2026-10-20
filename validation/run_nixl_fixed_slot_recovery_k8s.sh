#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Two-node Kubernetes validation for SGLang PR #42780.
#
# This deliberately uses kubectl to simulate the Dynamo controller boundary:
# delete the failed allocation, authorize a fixed-slot recovery, and create the
# replacement. The Dynamo replacement controller is not part of PR #42780.
#
# The script requires a digest-pinned image derived from the official SGLang
# CUDA image. It must replace Mooncake with a wheel/cache built from the pinned
# Mooncake commit against that image's Torch/CUDA stack and contain the exact
# PR source at /opt/pr-source with that source first on PYTHONPATH. The image
# digest is the immutable validation artifact; Pods do not download PR source.
#
# Final verdicts are conservative:
#   YES          correlated recovery reached ready and recovered-rank inference passed
#   NO           correlated terminal failure after all NIXL recovery prerequisites passed
#   INCONCLUSIVE infrastructure, timeout, or uncorrelated failure prevented either result
#
# Typical invocation (works even if a download loses its executable bit):
#   SGLANG_IMAGE=<derived-image@sha256:...> \
#   EXPECTED_IMAGE_ID=sha256:<derived-image-digest> \
#   RDMA_RESOURCE_KEY=rdma/rdma_shared_device_a \
#   RDMA_RESOURCE_COUNT=1 \
#   UCX_TLS=<cluster-specific-ucx-transports> \
#   UCX_NET_DEVICES=<cluster-specific-ucx-devices> \
#   MOONCAKE_IB_DEVICE=<cluster-specific-ib-devices> \
#   bash ./run_nixl_fixed_slot_recovery_k8s.sh
#
# The derived image must set MOONCAKE_BUILD_COMMIT to the full source commit
# used to build Mooncake and SGLANG_BASE_IMAGE_DIGEST to the official image
# digest from which it was derived. This is a self-attested compatibility
# claim, not proof of OCI parent lineage. Retain the pinned Dockerfile, build
# logs, and signed build provenance separately. It may retain
# EXPECTED_BASE_COMMIT when it changes only Mooncake; always provide
# SGLANG_IMAGE and EXPECTED_IMAGE_ID.
#
# Alternatively:
#   chmod +x ./run_nixl_fixed_slot_recovery_k8s.sh
#   ./run_nixl_fixed_slot_recovery_k8s.sh
#
# Important overrides:
#   NAMESPACE=sglang-nixl-recovery
#   MODEL=Qwen/Qwen1.5-MoE-A2.7B-Chat
#   MODEL_REVISION=ec052fda178e241c7c443468d2fa1db6618996be
#   GPU_RESOURCE_KEY=nvidia.com/gpu
#   RDMA_RESOURCE_KEY=rdma/rdma_shared_device_a # required; cluster-specific
#   RDMA_RESOURCE_COUNT=1
#   UCX_TLS=                                  # required; cluster-specific comma-separated transports
#   UCX_NET_DEVICES=                          # required; cluster-specific comma-separated device:port entries
#   MOONCAKE_IB_DEVICE=                       # required; cluster-specific comma-separated device names
#   NODE_SELECTOR_KEY=                        # optional
#   NODE_SELECTOR_VALUE=
#   HF_TOKEN_SECRET_NAME=                     # secret key must be HF_TOKEN
#   HF_CACHE_PVC=                             # optional shared model cache
#   IMAGE_PULL_SECRET=                        # optional
#   EXPECTED_NVIDIA_DRIVER_VERSION=           # optional exact runtime gate
#   EXPECTED_TORCH_CUDA_VERSION=              # optional exact runtime gate
#   EXPECTED_NCCL_VERSION=                    # optional exact runtime gate
#   EXPECTED_UCX_VERSION=                     # optional exact runtime gate
#   EXPECTED_NIXL_VERSION=                    # optional exact runtime gate
#   KUBECTL_REQUEST_TIMEOUT=30s
#   COMMAND_TIMEOUT_SECONDS=300
#   PREFLIGHT_TIMEOUT_SECONDS=120
#   STATUS_INTERVAL_SECONDS=30
#   STUCK_THRESHOLD_SECONDS=120
#   RECOVERY_TIMEOUT_SECONDS=900
#   POD_ACTIVE_DEADLINE_SECONDS=7200
#   CLEANUP_TIMEOUT_SECONDS=180
#   KEEP_RESOURCES=true                       # preserve pods after the run
#
# Evidence is written under ./recovery-evidence-<UTC timestamp>.

set -Eeuo pipefail

readonly PR_NUMBER="42780"
readonly EXPECTED_PR_SHA="f481ab6a87c4c4aea4ac38f040b051a0ee4da8ae"
readonly APP="sglang-nixl-recovery"
readonly OFFICIAL_BASE_IMAGE_DIGEST="sha256:e20a28a4badee7d3de71881e7c2c160c7079465bf1ac21edec31a99c2602507d"
readonly EXPECTED_BASE_COMMIT="e6072935bfa1036d4e20e8ed042ce1ff09872f57"
readonly DEFAULT_EXPECTED_MOONCAKE_COMMIT="1c54e233a22404692efd312739db749991d8d757"

NAMESPACE="${NAMESPACE:-sglang-nixl-recovery}"
SGLANG_IMAGE="${SGLANG_IMAGE:-}"
MODEL="${MODEL:-Qwen/Qwen1.5-MoE-A2.7B-Chat}"
MODEL_REVISION="${MODEL_REVISION:-ec052fda178e241c7c443468d2fa1db6618996be}"
GPU_RESOURCE_KEY="${GPU_RESOURCE_KEY:-nvidia.com/gpu}"
GPU_RESOURCE_COUNT="${GPU_RESOURCE_COUNT:-1}"
RDMA_RESOURCE_KEY="${RDMA_RESOURCE_KEY:-}"
RDMA_RESOURCE_COUNT="${RDMA_RESOURCE_COUNT:-1}"
UCX_NET_DEVICES="${UCX_NET_DEVICES:-}"
UCX_TLS="${UCX_TLS:-}"
MOONCAKE_IB_DEVICE="${MOONCAKE_IB_DEVICE:-}"
NODE_SELECTOR_KEY="${NODE_SELECTOR_KEY:-}"
NODE_SELECTOR_VALUE="${NODE_SELECTOR_VALUE:-}"
HF_TOKEN_SECRET_NAME="${HF_TOKEN_SECRET_NAME:-}"
HF_CACHE_PVC="${HF_CACHE_PVC:-}"
IMAGE_PULL_SECRET="${IMAGE_PULL_SECRET:-}"
EXPECTED_IMAGE_ID="${EXPECTED_IMAGE_ID:-}"
EXPECTED_BASE_IMAGE_DIGEST="${EXPECTED_BASE_IMAGE_DIGEST:-$OFFICIAL_BASE_IMAGE_DIGEST}"
EXPECTED_MOONCAKE_COMMIT="${EXPECTED_MOONCAKE_COMMIT:-$DEFAULT_EXPECTED_MOONCAKE_COMMIT}"
EXPECTED_NVIDIA_DRIVER_VERSION="${EXPECTED_NVIDIA_DRIVER_VERSION:-}"
EXPECTED_TORCH_CUDA_VERSION="${EXPECTED_TORCH_CUDA_VERSION:-}"
EXPECTED_NCCL_VERSION="${EXPECTED_NCCL_VERSION:-}"
EXPECTED_UCX_VERSION="${EXPECTED_UCX_VERSION:-}"
EXPECTED_NIXL_VERSION="${EXPECTED_NIXL_VERSION:-}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-30s}"
COMMAND_TIMEOUT_SECONDS="${COMMAND_TIMEOUT_SECONDS:-300}"
PREFLIGHT_TIMEOUT_SECONDS="${PREFLIGHT_TIMEOUT_SECONDS:-120}"
STATUS_INTERVAL_SECONDS="${STATUS_INTERVAL_SECONDS:-30}"
STUCK_THRESHOLD_SECONDS="${STUCK_THRESHOLD_SECONDS:-120}"
RECOVERY_TIMEOUT_SECONDS="${RECOVERY_TIMEOUT_SECONDS:-900}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-1800}"
LOCAL_PORT="${LOCAL_PORT:-21000}"
KEEP_RESOURCES="${KEEP_RESOURCES:-false}"
RUN_UPSTREAM_PREFLIGHT="${RUN_UPSTREAM_PREFLIGHT:-true}"
CLEANUP_TIMEOUT_SECONDS="${CLEANUP_TIMEOUT_SECONDS:-180}"
POD_ACTIVE_DEADLINE_SECONDS="${POD_ACTIVE_DEADLINE_SECONDS:-7200}"

RUN_ID="$(date -u +%Y%m%dt%H%M%Sz)"
NAMESPACE_CREATED_BY_RUN=false
PRIMARY_POD="${APP}-primary-${RUN_ID}"
FAILED_POD="${APP}-rank1-${RUN_ID}"
REPLACEMENT_POD="${APP}-replacement-${RUN_ID}"
PRIMARY_ALLOCATION_ID="initial-rank-0-${RUN_ID}"
FAILED_ALLOCATION_ID="initial-rank-1-${RUN_ID}"
REPLACEMENT_ALLOCATION_ID="replacement-rank-1-${RUN_ID}"
OPERATION_ID="recover-rank-1-${RUN_ID}"
SERVICE="${APP}-primary-${RUN_ID}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$(pwd)/recovery-evidence-${RUN_ID}}"
PF_PID=""
TEST_SUCCEEDED=false
VERDICT="INCONCLUSIVE"
VERDICT_REASON="validation did not reach a conclusive NIXL recovery result"
NIXL_RECOVERY_PRECONDITIONS_VERIFIED=false
PRIMARY_IMAGE_ID=""
FAILED_POD_UID=""
REPLACEMENT_POD_UID=""
CLEANUP_STATUS="NOT_STARTED"
CLEANUP_REASON="cleanup has not run"
CLEANUP_REMAINING=""
INTERRUPT_SIGNAL=""
FAILURE_COMMAND=""
FAILURE_LINE=""
FAILURE_EXIT_CODE=""
FAILURE_MESSAGE=""
EVENT_LOG="$EVIDENCE_DIR/events.log"
STAGE_LOG="$EVIDENCE_DIR/stages.log"

UPSTREAM_CHECKER_URL="https://raw.githubusercontent.com/ai-dynamo/dynamo/c2b0f90cbee928b40f10d552b283a0031a9fa5cd/.agents/skills/dynamo-interconnect-check/scripts/check_interconnect.py"

emit() {
  local level="$1"
  shift
  local line
  line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${level}: $*"
  printf '%s\n' "$line"
  if [[ -d "$EVIDENCE_DIR" ]]; then
    printf '%s\n' "$line" >>"$EVENT_LOG"
  fi
}

die() {
  FAILURE_MESSAGE="$*"
  FAILURE_EXIT_CODE="1"
  FAILURE_LINE="${BASH_LINENO[0]:-0}"
  if [[ "$VERDICT" == "INCONCLUSIVE" ]]; then
    VERDICT_REASON="$*"
  fi
  emit FAILURE "$*" >&2
  exit 1
}

note() {
  emit INFO "$*"
}

warn() {
  emit WARNING "$*"
}

waiting() {
  emit WAITING "$*"
}

stuck() {
  emit STUCK "$*"
}

debug() {
  emit DEBUG "$*"
}

succeed() {
  emit SUCCESS "$*"
}

mark_stage() {
  local stage="$1" status="$2"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" "$status" \
    >>"$STAGE_LOG"
  note "stage=$stage status=$status"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

kube() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

bool_is_true() {
  case "$1" in
    [Tt][Rr][Uu][Ee]) return 0 ;;
    *) return 1 ;;
  esac
}

validate_scalar() {
  local name="$1" value="$2"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$name must be one line"
}

validate_positive_integer() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name must be a positive integer"
}

validate_bool() {
  local name="$1" value="$2"
  case "$value" in
    [Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]) return 0 ;;
    *) die "$name must be true or false" ;;
  esac
}

validate_kubectl_timeout() {
  [[ "$KUBECTL_REQUEST_TIMEOUT" =~ ^[1-9][0-9]*(ms|s|m|h)$ ]] || \
    die "KUBECTL_REQUEST_TIMEOUT must be a positive duration such as 30s or 2m"
}

validate_required_rdma_configuration() {
  local entry found_ucx_device=false
  local -a entries

  [[ -n "$RDMA_RESOURCE_KEY" ]] || die "RDMA_RESOURCE_KEY is required for this validation"
  [[ -n "$UCX_TLS" ]] || die "UCX_TLS is required for this validation"
  [[ -n "$UCX_NET_DEVICES" ]] || die "UCX_NET_DEVICES is required for this validation"
  [[ -n "$MOONCAKE_IB_DEVICE" ]] || die "MOONCAKE_IB_DEVICE is required for this validation"

  [[ "$RDMA_RESOURCE_KEY" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?/[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] || \
    die "RDMA_RESOURCE_KEY must be a Kubernetes extended resource name such as rdma/rdma_shared_device_a"

  IFS=',' read -r -a entries <<<"$UCX_NET_DEVICES"
  for entry in "${entries[@]}"; do
    if [[ "$entry" == "lo" ]]; then
      continue
    fi
    [[ "$entry" =~ ^[A-Za-z0-9_.-]+:[1-9][0-9]*$ ]] || \
      die "UCX_NET_DEVICES entries must be device:port values, optionally followed by ,lo"
    found_ucx_device=true
  done
  [[ "$found_ucx_device" == true ]] || \
    die "UCX_NET_DEVICES must contain at least one RDMA device:port entry"

  [[ "$MOONCAKE_IB_DEVICE" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || \
    die "MOONCAKE_IB_DEVICE must contain one or more comma-separated RDMA device names"
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
try:
    completed = subprocess.run(sys.argv[2:], timeout=timeout_seconds)
except subprocess.TimeoutExpired:
    print(
        f"command timed out after {timeout_seconds}s: {' '.join(sys.argv[2:])}",
        file=sys.stderr,
    )
    raise SystemExit(124)
raise SystemExit(completed.returncode)
PY
}

kube_with_timeout() {
  local timeout_seconds="$1" rc
  shift
  if run_with_timeout "$timeout_seconds" \
    kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"; then
    return 0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 124 ]]; then
    stuck "Kubernetes subprocess exceeded ${timeout_seconds}s: kubectl $*"
  fi
  return "$rc"
}

on_err() {
  local rc=$?
  FAILURE_EXIT_CODE="$rc"
  FAILURE_LINE="${BASH_LINENO[0]:-0}"
  FAILURE_COMMAND="$BASH_COMMAND"
  FAILURE_MESSAGE="command failed (exit $rc) at line $FAILURE_LINE"
  if [[ "$VERDICT" == "INCONCLUSIVE" ]]; then
    VERDICT_REASON="$FAILURE_MESSAGE"
  fi
  emit FAILURE "command failed (exit $rc) at line $FAILURE_LINE: $FAILURE_COMMAND" >&2
  return "$rc"
}

on_signal() {
  local signal_name="$1" exit_code="$2"
  INTERRUPT_SIGNAL="$signal_name"
  FAILURE_EXIT_CODE="$exit_code"
  FAILURE_MESSAGE="controller interrupted by signal $signal_name"
  VERDICT="INCONCLUSIVE"
  VERDICT_REASON="$FAILURE_MESSAGE"
  warn "$FAILURE_MESSAGE; evidence collection and verified cleanup will run"
  exit "$exit_code"
}

write_summary() {
  local rc="$1"
  {
    echo "# SGLang PR #${PR_NUMBER} Kubernetes recovery verdict: ${VERDICT}"
    echo
    echo "- Verdict: **${VERDICT}**"
    echo "- Verdict reason: ${VERDICT_REASON}"
    echo "- Run: \`${RUN_ID}\`"
    echo "- Expected PR head: \`${EXPECTED_PR_SHA}\`"
    echo "- Validation mode: single pinned image with embedded PR source"
    echo "- Base image: \`${SGLANG_IMAGE}\`"
    echo "- Expected base commit: \`${EXPECTED_BASE_COMMIT}\`"
    echo "- PR source: embedded in the pinned image"
    echo "- Expected image ID: \`${EXPECTED_IMAGE_ID}\`"
    echo "- Expected base image digest: \`${EXPECTED_BASE_IMAGE_DIGEST}\`"
    echo "- Expected Mooncake build commit: \`${EXPECTED_MOONCAKE_COMMIT}\`"
    echo "- Model revision: \`${MODEL_REVISION}\`"
    echo "- Resolved image ID: \`${PRIMARY_IMAGE_ID:-unavailable}\`"
    echo "- Namespace: \`${NAMESPACE}\`"
    echo "- Operation: \`${OPERATION_ID}\`"
    echo "- RDMA resource: \`${RDMA_RESOURCE_KEY}\`"
    echo "- RDMA resource count: \`${RDMA_RESOURCE_COUNT}\`"
    echo "- UCX devices: \`${UCX_NET_DEVICES}\`"
    echo "- UCX transports: \`${UCX_TLS}\`"
    echo "- Mooncake IB devices: \`${MOONCAKE_IB_DEVICE}\`"
    echo "- Failed rank-1 Pod UID: \`${FAILED_POD_UID:-unavailable}\`"
    echo "- Replacement rank-1 Pod UID: \`${REPLACEMENT_POD_UID:-unavailable}\`"
    echo "- GPU Pod active deadline: \`${POD_ACTIVE_DEADLINE_SECONDS}s\`"
    echo "- Exit code: \`${rc}\`"
    [[ -z "$FAILURE_MESSAGE" ]] || echo "- Error: ${FAILURE_MESSAGE}"
    if [[ -n "$FAILURE_COMMAND" ]]; then
      echo "- Failed line: \`${FAILURE_LINE}\`"
      echo "- Failed command: \`${FAILURE_COMMAND//\`/\\\`}\`"
    fi
    echo
    echo "## Verdict criteria"
    echo
    echo "- **YES:** the correlated recovery reached \`ready\` for the expected operation, allocation, rank offset, and topology generation, then inference succeeded through recovered rank 1."
    echo "- **NO:** after prerequisites and baseline succeeded, SGLang reported \`recovery_phase=failed\` and \`recovery_succeeded=false\` for that exact correlated NIXL fixed-slot recovery operation."
    echo "- **INCONCLUSIVE:** RBAC, image, model, scheduling, network, RDMA, timeout, pod, evidence, or any uncorrelated/unclassified failure prevented a valid YES/NO result."
    echo
    echo "## Evidence"
    echo
    echo "Attach this directory (or its archive) with \`run.log\`, \`run.env\`, pod logs/descriptions, state JSON, image IDs, and old-process termination proof."
    echo
    echo "> Warning: this validates the exact PR Python source over a pinned official image; it is not evidence of a container built wholly from the PR."
    if [[ -s "$EVENT_LOG" ]]; then
      echo
      echo "## Recent status messages"
      echo
      echo '```text'
      tail -n 40 "$EVENT_LOG"
      echo '```'
    fi
  } >"$EVIDENCE_DIR/SUMMARY.md"
}

collect_evidence() {
  local rc="${1:-0}" evidence_rc=0
  mkdir -p "$EVIDENCE_DIR"
  note "Collecting final Kubernetes evidence for exit code $rc"
  {
    echo "pr_number=$PR_NUMBER"
    echo "expected_pr_sha=$EXPECTED_PR_SHA"
    echo "run_id=$RUN_ID"
    echo "namespace=$NAMESPACE"
    echo "image=$SGLANG_IMAGE"
    echo "validation_mode=single-pinned-image-with-embedded-pr-source"
    echo "expected_base_commit=$EXPECTED_BASE_COMMIT"
    echo "model=$MODEL"
    echo "model_revision=$MODEL_REVISION"
    echo "operation_id=$OPERATION_ID"
    echo "rdma_resource_key=$RDMA_RESOURCE_KEY"
    echo "rdma_resource_count=$RDMA_RESOURCE_COUNT"
    echo "ucx_net_devices=$UCX_NET_DEVICES"
    echo "ucx_tls=$UCX_TLS"
    echo "mooncake_ib_device=$MOONCAKE_IB_DEVICE"
    echo "expected_image_id=$EXPECTED_IMAGE_ID"
    echo "expected_base_image_digest=$EXPECTED_BASE_IMAGE_DIGEST"
    echo "expected_mooncake_commit=$EXPECTED_MOONCAKE_COMMIT"
    echo "resolved_image_id=$PRIMARY_IMAGE_ID"
    echo "failed_pod_uid=$FAILED_POD_UID"
    echo "replacement_pod_uid=$REPLACEMENT_POD_UID"
    echo "pod_active_deadline_seconds=$POD_ACTIVE_DEADLINE_SECONDS"
    echo "namespace_created_by_run=$NAMESPACE_CREATED_BY_RUN"
    echo "failure_line=$FAILURE_LINE"
    echo "failure_exit_code=$FAILURE_EXIT_CODE"
    printf 'failure_message=%q\n' "$FAILURE_MESSAGE"
    printf 'failure_command=%q\n' "$FAILURE_COMMAND"
    echo "exit_code=$rc"
    echo "test_succeeded=$TEST_SUCCEEDED"
    echo "nixl_recovery_preconditions_verified=$NIXL_RECOVERY_PRECONDITIONS_VERIFIED"
    echo "verdict=$VERDICT"
    printf 'verdict_reason=%q\n' "$VERDICT_REASON"
    echo "interrupt_signal=$INTERRUPT_SIGNAL"
  } >"$EVIDENCE_DIR/run.env" || evidence_rc=1

  if ! kube get pods -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RUN_ID" \
    -o wide >"$EVIDENCE_DIR/pods.txt" 2>&1; then
    warn "could not collect final pod listing; see pods.txt"
    evidence_rc=1
  fi
  if ! kube get events -n "$NAMESPACE" --sort-by=.lastTimestamp \
    >"$EVIDENCE_DIR/events.txt" 2>&1; then
    warn "could not collect final Kubernetes events; see events.txt"
    evidence_rc=1
  fi

  local pod
  for pod in "$PRIMARY_POD" "$FAILED_POD" "$REPLACEMENT_POD"; do
    debug "collecting logs and description for pod=$pod"
    if kube get pod -n "$NAMESPACE" "$pod" >/dev/null 2>&1; then
      if ! kube logs -n "$NAMESPACE" "$pod" --timestamps \
        >"$EVIDENCE_DIR/${pod}.log" 2>&1; then
        warn "could not collect application log for $pod; see ${pod}.log"
        evidence_rc=1
      fi
      if ! kube logs -n "$NAMESPACE" "$pod" -c mooncake-torch-compatibility --timestamps \
        >"$EVIDENCE_DIR/${pod}.mooncake-init.log" 2>&1; then
        warn "could not collect Mooncake init log for $pod; see ${pod}.mooncake-init.log"
        evidence_rc=1
      fi
      if ! kube describe pod -n "$NAMESPACE" "$pod" \
        >"$EVIDENCE_DIR/${pod}.describe.txt" 2>&1; then
        warn "could not describe $pod; see ${pod}.describe.txt"
        evidence_rc=1
      fi
    elif [[ -s "$EVIDENCE_DIR/${pod}.before-deletion.log" ]]; then
      note "preserved pre-deletion evidence for absent pod=$pod"
    else
      warn "pod=$pod is absent and no pre-deletion log was preserved"
      evidence_rc=1
    fi
  done

  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" >/dev/null 2>&1 || true
    PF_PID=""
  fi

  [[ "$evidence_rc" -eq 0 ]]
}

list_run_resources() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" get pod,service \
    -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RUN_ID" \
    --ignore-not-found -o name 2>"$EVIDENCE_DIR/cleanup-query.stderr"
}

record_cleanup_outcome() {
  local cleanup_rc="$1" final_rc="$2"
  {
    echo "cleanup_status=$CLEANUP_STATUS"
    printf 'cleanup_reason=%q\n' "$CLEANUP_REASON"
    printf 'cleanup_remaining=%q\n' "$CLEANUP_REMAINING"
    echo "cleanup_exit_code=$cleanup_rc"
    echo "final_exit_code=$final_rc"
  } >>"$EVIDENCE_DIR/run.env" || return 1
  {
    echo
    echo "## Cleanup"
    echo
    echo "- Status: **$CLEANUP_STATUS**"
    echo "- Reason: $CLEANUP_REASON"
    echo "- Remaining run resources: \`${CLEANUP_REMAINING:-none}\`"
    echo "- Namespace created by this run: \`$NAMESPACE_CREATED_BY_RUN\`"
  } >>"$EVIDENCE_DIR/SUMMARY.md"
}

archive_evidence() {
  local archive_path temporary_archive
  archive_path="$EVIDENCE_DIR/evidence-${RUN_ID}.tar.gz"
  temporary_archive="$(mktemp "/tmp/${APP}-${RUN_ID}.XXXXXX.tar.gz")"
  if (cd "$EVIDENCE_DIR" && tar -czf "$temporary_archive" .); then
    mv "$temporary_archive" "$archive_path"
    note "Shareable evidence archive: $archive_path"
  else
    warn "evidence archive creation failed; the uncompressed evidence directory remains available"
    return 1
  fi
}

cleanup() {
  local deadline=$((SECONDS + CLEANUP_TIMEOUT_SECONDS)) remaining
  if ! command -v kubectl >/dev/null 2>&1; then
    CLEANUP_STATUS="RESOURCES_NOT_DELETED"
    CLEANUP_REASON="kubectl is unavailable, so cleanup cannot be verified"
    return 1
  fi
  if ! kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    CLEANUP_STATUS="RESOURCES_DELETED"
    CLEANUP_REASON="target namespace is absent, so no run resources remain"
    return 0
  fi
  if bool_is_true "$KEEP_RESOURCES"; then
    CLEANUP_STATUS="RESOURCES_RETAINED"
    CLEANUP_REASON="resources intentionally retained because KEEP_RESOURCES=$KEEP_RESOURCES"
    if ! CLEANUP_REMAINING="$(list_run_resources)"; then
      CLEANUP_STATUS="RESOURCES_RETENTION_UNVERIFIED"
      CLEANUP_REASON="could not list intentionally retained run resources"
      return 1
    fi
    return 0
  fi
  if ! kube delete pod,service -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RUN_ID" --ignore-not-found --wait=false; then
    CLEANUP_STATUS="RESOURCES_NOT_DELETED"
    CLEANUP_REASON="kubectl delete rejected run-labeled resources"
    return 1
  fi
  while (( SECONDS < deadline )); do
    if ! remaining="$(list_run_resources)"; then
      CLEANUP_STATUS="RESOURCES_NOT_DELETED"
      CLEANUP_REASON="cleanup verification query failed"
      return 1
    fi
    [[ -z "$remaining" ]] && break
    CLEANUP_REMAINING="${remaining//$'\n'/,}"
    waiting "resource deletion pending: $CLEANUP_REMAINING"
    sleep 2
  done
  if ! remaining="$(list_run_resources)" || [[ -n "$remaining" ]]; then
    CLEANUP_STATUS="RESOURCES_NOT_DELETED"
    CLEANUP_REASON="run-labeled resources remained after ${CLEANUP_TIMEOUT_SECONDS}s"
    CLEANUP_REMAINING="${remaining//$'\n'/,}"
    return 1
  fi
  if [[ "$NAMESPACE_CREATED_BY_RUN" == true ]]; then
    if ! kube delete namespace "$NAMESPACE" --ignore-not-found --wait=false; then
      CLEANUP_STATUS="RESOURCES_NOT_DELETED"
      CLEANUP_REASON="run-created namespace deletion was rejected"
      return 1
    fi
    deadline=$((SECONDS + CLEANUP_TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
      if ! kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
        CLEANUP_STATUS="RESOURCES_DELETED"
        CLEANUP_REASON="run-labeled resources and the run-created namespace are absent"
        return 0
      fi
      waiting "namespace deletion pending: $NAMESPACE"
      sleep 2
    done
    CLEANUP_STATUS="RESOURCES_NOT_DELETED"
    CLEANUP_REASON="run-created namespace deletion timed out after ${CLEANUP_TIMEOUT_SECONDS}s"
    CLEANUP_REMAINING="namespace/$NAMESPACE"
    return 1
  fi
  CLEANUP_STATUS="RESOURCES_DELETED"
  CLEANUP_REASON="all run-labeled resources are absent; pre-existing namespace was preserved"
}

on_exit() {
  local rc=$?
  local evidence_rc=0 cleanup_rc=0 summary_rc=0 record_rc=0 archive_rc=0
  trap - EXIT
  trap 'warn "additional HUP received during finalization"' HUP
  trap 'warn "additional INT received during finalization"' INT
  trap 'warn "additional TERM received during finalization"' TERM
  set +e
  if [[ "$rc" -eq 0 && "$TEST_SUCCEEDED" == true && "$VERDICT" == "YES" ]]; then
    :
  elif [[ "$VERDICT" == "NO" ]]; then
    [[ "$rc" -ne 0 ]] || rc=1
    emit FAILURE "VERDICT=NO: $VERDICT_REASON" >&2
  else
    VERDICT="INCONCLUSIVE"
    if [[ -n "$FAILURE_MESSAGE" ]]; then
      VERDICT_REASON="$FAILURE_MESSAGE"
    elif [[ "$rc" -ne 0 ]]; then
      VERDICT_REASON="validation exited with code $rc before a conclusive NIXL result"
    else
      VERDICT_REASON="validation ended without satisfying the YES or NO criteria"
    fi
    warn "VERDICT=INCONCLUSIVE: $VERDICT_REASON"
  fi
  collect_evidence "$rc" || evidence_rc=$?
  if [[ "$evidence_rc" -ne 0 && "$rc" -eq 0 ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_REASON="evidence collection was incomplete"
    rc="$evidence_rc"
  fi
  cleanup || cleanup_rc=$?
  if [[ "$cleanup_rc" -ne 0 && "$rc" -eq 0 ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_REASON="cleanup was not verified: $CLEANUP_REASON"
    rc="$cleanup_rc"
  fi
  write_summary "$rc" || summary_rc=$?
  if [[ "$summary_rc" -ne 0 && "$rc" -eq 0 ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_REASON="summary could not be written"
    rc="$summary_rc"
  fi
  record_cleanup_outcome "$cleanup_rc" "$rc" || record_rc=$?
  if [[ "$record_rc" -ne 0 && "$rc" -eq 0 ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_REASON="cleanup outcome could not be persisted"
    rc="$record_rc"
  fi
  archive_evidence || archive_rc=$?
  if [[ "$archive_rc" -ne 0 && "$rc" -eq 0 ]]; then
    VERDICT="INCONCLUSIVE"
    VERDICT_REASON="evidence archive could not be created"
    rc="$archive_rc"
  fi
  exit "$rc"
}

yaml_optional_env() {
  local name="$1" value="$2"
  if [[ -n "$value" ]]; then
    cat <<EOF
        - name: ${name}
          value: "${value}"
EOF
  fi
}

yaml_optional_resources() {
  if [[ -n "$RDMA_RESOURCE_KEY" ]]; then
    cat <<EOF
          ${RDMA_RESOURCE_KEY}: "${RDMA_RESOURCE_COUNT}"
EOF
  fi
}

yaml_optional_node_selector() {
  if [[ -n "$NODE_SELECTOR_KEY" ]]; then
    cat <<EOF
  nodeSelector:
    ${NODE_SELECTOR_KEY}: "${NODE_SELECTOR_VALUE}"
EOF
  fi
}

yaml_optional_image_pull_secret() {
  if [[ -n "$IMAGE_PULL_SECRET" ]]; then
    cat <<EOF
  imagePullSecrets:
    - name: "${IMAGE_PULL_SECRET}"
EOF
  fi
}

yaml_optional_hf_secret() {
  if [[ -n "$HF_TOKEN_SECRET_NAME" ]]; then
    cat <<EOF
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: "${HF_TOKEN_SECRET_NAME}"
              key: HF_TOKEN
EOF
  fi
}

yaml_optional_cache_mount() {
  if [[ -n "$HF_CACHE_PVC" ]]; then
    cat <<'EOF'
        - name: hf-cache
          mountPath: /root/.cache/huggingface
EOF
  fi
}

yaml_optional_cache_volume() {
  if [[ -n "$HF_CACHE_PVC" ]]; then
    cat <<EOF
    - name: hf-cache
      persistentVolumeClaim:
        claimName: "${HF_CACHE_PVC}"
EOF
  fi
}

render_common_pod() {
  local pod_name="$1" role="$2" node_rank="$3" port="$4"
  local allocation_id="$5" join_mode="$6" allocation_index="${7:-}"
  local allocation_index_arg="" geometry_args=""
  if [[ "$join_mode" == "auto" ]]; then
    [[ -n "$allocation_index" ]] || die "auto join mode requires an allocation index"
    printf -v allocation_index_arg \
      '            --elastic-ep-allocation-index %s \\\n' "$allocation_index"
  elif [[ -n "$allocation_index" ]]; then
    die "only auto join mode may set an allocation index"
  fi
  if [[ "$join_mode" != "auto" ]]; then
    geometry_args="            --tp 2 \\
            --nnodes 2 \\
            --node-rank ${node_rank} \\
            --attn-dp-size 2 \\"
  fi
  local mooncake_device_arg=""
  if [[ -n "$MOONCAKE_IB_DEVICE" ]]; then
    printf -v mooncake_device_arg \
      '            --mooncake-ib-device %s \\\n' "$MOONCAKE_IB_DEVICE"
  fi

  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: "${pod_name}"
  namespace: "${NAMESPACE}"
  labels:
    app.kubernetes.io/name: "${APP}"
    app.kubernetes.io/instance: "${RUN_ID}"
    recovery-role: "${role}"
spec:
  restartPolicy: Never
  activeDeadlineSeconds: ${POD_ACTIVE_DEADLINE_SECONDS}
$(yaml_optional_image_pull_secret)
$(yaml_optional_node_selector)
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/instance: "${RUN_ID}"
          topologyKey: kubernetes.io/hostname
  initContainers:
    - name: mooncake-torch-compatibility
      image: "${SGLANG_IMAGE}"
      imagePullPolicy: Always
      command: ["/bin/bash", "-lc"]
      env:
        - name: EXPECTED_MOONCAKE_COMMIT
          value: "${EXPECTED_MOONCAKE_COMMIT}"
        - name: EXPECTED_BASE_IMAGE_DIGEST
          value: "${EXPECTED_BASE_IMAGE_DIGEST}"
      args:
        - |
          set -Eeuo pipefail
          report="\$(python3 -m mooncake.pg --report)"
          printf '%s\n' "\$report"
          cached_adapter="\$(awk -F': ' '/^  cached adapter:/ { print \$2; exit }' <<<"\$report")"
          [[ -n "\$cached_adapter" && "\$cached_adapter" != "missing" ]] || {
            echo "Mooncake PG adapter cache is missing; rebuild the derived image with a prebuilt adapter." >&2
            exit 1
          }
          python3 - <<'PY'
          import importlib
          import os
          import torch

          expected_commit = os.environ["EXPECTED_MOONCAKE_COMMIT"]
          actual_commit = os.environ.get("MOONCAKE_BUILD_COMMIT")
          expected_base_image_digest = os.environ["EXPECTED_BASE_IMAGE_DIGEST"]
          actual_base_image_digest = os.environ.get("SGLANG_BASE_IMAGE_DIGEST")
          if actual_commit != expected_commit:
              raise SystemExit(
                  "Mooncake build commit mismatch: "
                  f"expected {expected_commit}, got {actual_commit!r}."
              )
          if actual_base_image_digest != expected_base_image_digest:
              raise SystemExit(
                  "SGLang base image digest mismatch: "
                  f"expected {expected_base_image_digest}, got "
                  f"{actual_base_image_digest!r}."
              )

          try:
              importlib.import_module("mooncake.pg")
          except ImportError as error:
              raise SystemExit(
                  "Mooncake process-group import failed for "
                  f"torch=={torch.__version__}: {error}. Use a compatible "
                  "digest-pinned image."
              ) from error

          print(
              "SUCCESS: Mooncake build commit "
              f"{actual_commit} supports torch=={torch.__version__}"
          )
          PY
  containers:
    - name: sglang
      image: "${SGLANG_IMAGE}"
      imagePullPolicy: Always
      command: ["/bin/bash", "-lc"]
      args:
        - |
          set -euo pipefail
          test "\$(cat /opt/pr-source/.pr-head)" = "${EXPECTED_PR_SHA}"
          test "\${SGLANG_RUST_BUILD_MODE}" = never
          python3 -c 'import pathlib,sglang; p=pathlib.Path(sglang.__file__).resolve(); assert str(p).startswith("/opt/pr-source/python/"), p; print("SUCCESS: embedded PR source imported from", p)'
          python3 -c 'from pathlib import Path; from sglang.srt.mem_cache.rust_tree_core.extension import bindings; p = Path(bindings.__file__).resolve(); assert str(p).startswith("/opt/pr-source/python/"), p; binding = bindings.RustUnifiedTreeCoreBinding; assert hasattr(binding, "adjust_component_size"), binding; assert hasattr(binding, "collect_path_info"), binding; print("SUCCESS: Rust TreeCore imported from", p)'
          sglang serve \\
            --model-path "${MODEL}" \\
            --revision "${MODEL_REVISION}" \\
            --host 0.0.0.0 \\
            --port "${port}" \\
            --device cuda \\
            --trust-remote-code \\
${geometry_args}
            --dist-init-addr "${SERVICE}:26555" \\
            --enable-dp-lm-head \\
            --elastic-ep-backend mooncake \\
            --moe-a2a-backend nixl \\
            --moe-runner-backend deep_gemm \\
            --deepep-mode low_latency \\
            --moe-dense-tp-size 1 \\
            --disable-custom-all-reduce \\
            --enable-eplb \\
            --ep-num-redundant-experts 2 \\
            --elastic-ep-initial-size 2 \\
            --max-ep-size 3 \\
            --elastic-ep-recovery-policy fixed_slot \\
            --elastic-ep-allocation-id "${allocation_id}" \\
            --elastic-ep-join-mode "${join_mode}" \\
${allocation_index_arg}${mooncake_device_arg}            --cuda-graph-backend-prefill disabled \\
            --cuda-graph-backend-decode full \\
--cuda-graph-max-bs-decode 16 \\
--mem-fraction-static 0.7 &
          sglang_pid=\$!
          printf '%s\\n' "\$sglang_pid" >/tmp/sglang.pid
          wait "\$sglang_pid"
      env:
        - name: PYTHONUNBUFFERED
          value: "1"
        - name: PYTHONPATH
          value: "/opt/pr-source/python"
        - name: SGLANG_RUST_BUILD_MODE
          value: "never"
        - name: SGLANG_NIXL_EP_BF16_DISPATCH
          value: "1"
        - name: SGLANG_EXPECTED_PR_SHA
          value: "${EXPECTED_PR_SHA}"
        - name: NCCL_DEBUG
          value: INFO
        - name: NCCL_IB_DISABLE
          value: "0"
        - name: UCX_TLS
          value: "${UCX_TLS}"
        - name: UCX_LOG_LEVEL
          value: info
$(yaml_optional_env UCX_NET_DEVICES "$UCX_NET_DEVICES")
$(yaml_optional_hf_secret)
      resources:
        limits:
          ${GPU_RESOURCE_KEY}: "${GPU_RESOURCE_COUNT}"
$(yaml_optional_resources)
        requests:
          ${GPU_RESOURCE_KEY}: "${GPU_RESOURCE_COUNT}"
$(yaml_optional_resources)
      securityContext:
        capabilities:
          add: ["IPC_LOCK"]
      volumeMounts:
        - name: dshm
          mountPath: /dev/shm
$(yaml_optional_cache_mount)
  volumes:
    - name: dshm
      emptyDir:
        medium: Memory
$(yaml_optional_cache_volume)
EOF
}

wait_for_pod_running() {
  local pod="$1"
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  local next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
  local slow_at=$((SECONDS + STUCK_THRESHOLD_SECONDS)) warned_slow=false
  while (( SECONDS < deadline )); do
    local phase reason init_reason init_failure init_name init_exit init_message
    phase="$(kube get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Running" ]] && return 0
    [[ "$phase" == "Failed" || "$phase" == "Succeeded" ]] && break
    reason="$(kube get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    init_reason="$(kube get pod -n "$NAMESPACE" "$pod" -o json 2>/dev/null | jq -r \
      '[.status.initContainerStatuses[]? | select(.state.waiting.reason != null) | "\(.name)=\(.state.waiting.reason)"] | join(",")' 2>/dev/null || true)"
    init_failure="$(kube get pod -n "$NAMESPACE" "$pod" -o json 2>/dev/null | jq -r \
      '[.status.initContainerStatuses[]? | select((.state.terminated.exitCode // 0) != 0) | "\(.name)\t\(.state.terminated.exitCode)\t\(.state.terminated.message // "")"] | .[0] // empty' 2>/dev/null || true)"
    if [[ -n "$init_failure" ]]; then
      IFS=$'\t' read -r init_name init_exit init_message <<<"$init_failure"
      kube logs -n "$NAMESPACE" "$pod" -c "$init_name" --timestamps >&2 || true
      die "$pod init container $init_name failed: exit_code=$init_exit message=${init_message:-none}"
    fi
    if [[ "$reason" =~ ^(ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CrashLoopBackOff)$ || \
          "$init_reason" =~ ^(ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CrashLoopBackOff)$ ]]; then
      kube describe pod -n "$NAMESPACE" "$pod" >&2 || true
      die "$pod cannot start: container_reason=${reason:-none} init_reason=${init_reason:-none}"
    fi
    if (( SECONDS >= next_status )); then
      waiting "$pod: phase=${phase:-unknown}, container_reason=${reason:-none}, init_reason=${init_reason:-none}"
      next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
    fi
    if [[ "$warned_slow" == false ]] && (( SECONDS >= slow_at )); then
      warn "$pod startup has exceeded ${STUCK_THRESHOLD_SECONDS}s; continuing until ${STARTUP_TIMEOUT_SECONDS}s timeout"
      warned_slow=true
    fi
    sleep 5
  done
  kube describe pod -n "$NAMESPACE" "$pod" >&2 || true
  stuck "$pod did not reach Running before the ${STARTUP_TIMEOUT_SECONDS}s timeout"
  die "$pod did not reach Running"
}

assert_pod_alive() {
  local pod="$1" snapshot phase terminated exit_code reason
  snapshot="$(kube get pod -n "$NAMESPACE" "$pod" -o json 2>/dev/null)" || die "$pod disappeared"
  phase="$(jq -r '.status.phase // "Unknown"' <<<"$snapshot")"
  terminated="$(jq -r '.status.containerStatuses[0].state.terminated != null' <<<"$snapshot")"
  if [[ "$phase" == "Failed" || "$phase" == "Succeeded" || "$terminated" == "true" ]]; then
    printf '%s\n' "$snapshot" >"$EVIDENCE_DIR/${pod}.unexpected-termination.json"
    kube logs -n "$NAMESPACE" "$pod" --timestamps >"$EVIDENCE_DIR/${pod}.unexpected-termination.log" 2>&1 || true
    exit_code="$(jq -r '.status.containerStatuses[0].state.terminated.exitCode // "unknown"' <<<"$snapshot")"
    reason="$(jq -r '.status.containerStatuses[0].state.terminated.reason // .status.reason // "unknown"' <<<"$snapshot")"
    die "$pod terminated unexpectedly: phase=$phase reason=$reason exit_code=$exit_code"
  fi
}

verify_pod_image() {
  local pod="$1" image_id expected_digest
  image_id="$(kube get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.containerStatuses[0].imageID}')"
  [[ -n "$image_id" ]] || die "$pod has no resolved runtime image ID"
  printf '%s\t%s\n' "$pod" "$image_id" | tee -a "$EVIDENCE_DIR/image-ids.txt"
  expected_digest="${EXPECTED_IMAGE_ID##*@}"
  if [[ "$image_id" != "$EXPECTED_IMAGE_ID" && "$image_id" != *"@$expected_digest" && "$image_id" != *":$expected_digest" ]]; then
    die "$pod image ID $image_id does not match EXPECTED_IMAGE_ID=$EXPECTED_IMAGE_ID"
  fi
  if [[ -z "$PRIMARY_IMAGE_ID" ]]; then
    PRIMARY_IMAGE_ID="$image_id"
  elif [[ "$image_id" != "$PRIMARY_IMAGE_ID" ]]; then
    die "$pod image ID $image_id differs from primary image ID $PRIMARY_IMAGE_ID"
  fi
}

require_permission() {
  local verb="$1" resource="$2" scope="${3:-namespaced}" answer
  if [[ "$scope" == "cluster" ]]; then
    answer="$(kube auth can-i "$verb" "$resource" 2>/dev/null || true)"
  else
    answer="$(kube auth can-i "$verb" "$resource" -n "$NAMESPACE" 2>/dev/null || true)"
  fi
  [[ "$answer" == "yes" ]] || die "missing Kubernetes permission: $verb $resource ($scope)"
}

check_prerequisite_permissions() {
  local check
  for check in \
    "get pods" "list pods" "create pods" "delete pods" \
    "get pods/log" "create pods/exec" "create pods/portforward" \
    "get services" "create services" "delete services" \
    "list events"; do
    require_permission ${check}
  done
  require_permission get namespaces cluster
  require_permission get nodes cluster
  require_permission list nodes cluster
}

kill_and_confirm_failed_allocation() {
  local pod="$1" deadline next_status snapshot terminated signal exit_code phase
  kube get pod -n "$NAMESPACE" "$pod" -o json >"$EVIDENCE_DIR/${pod}.before-kill.json"
  FAILED_POD_UID="$(jq -r '.metadata.uid // empty' "$EVIDENCE_DIR/${pod}.before-kill.json")"
  [[ -n "$FAILED_POD_UID" ]] || die "failed allocation pod has no Kubernetes UID: pod=$pod"
  printf '%s\n' "$FAILED_POD_UID" >"$EVIDENCE_DIR/${pod}.uid"
  note "Recorded failed allocation identity: pod=$pod uid=$FAILED_POD_UID"
  note "Sending SIGKILL to the recorded SGLang process in $pod"
  set +e
  kube_with_timeout "$COMMAND_TIMEOUT_SECONDS" exec -n "$NAMESPACE" "$pod" -- bash -lc \
    'test -s /tmp/sglang.pid; pid=$(cat /tmp/sglang.pid); kill -KILL "$pid"' \
    >"$EVIDENCE_DIR/${pod}.kill-command.txt" 2>&1
  printf 'kubectl_exec_exit_code=%s\n' "$?" >>"$EVIDENCE_DIR/${pod}.kill-command.txt"
  set -e

  deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS))
  next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
  while (( SECONDS < deadline )); do
    snapshot="$(kube get pod -n "$NAMESPACE" "$pod" -o json 2>/dev/null || true)"
    if [[ -n "$snapshot" ]]; then
      terminated="$(jq -r '.status.containerStatuses[0].state.terminated != null' <<<"$snapshot")"
      phase="$(jq -r '.status.phase // "Unknown"' <<<"$snapshot")"
      if [[ "$terminated" == "true" ]]; then
        signal="$(jq -r '.status.containerStatuses[0].state.terminated.signal // 0' <<<"$snapshot")"
        exit_code="$(jq -r '.status.containerStatuses[0].state.terminated.exitCode // -1' <<<"$snapshot")"
        printf '%s\n' "$snapshot" >"$EVIDENCE_DIR/${pod}.termination-proof.json"
        [[ "$signal" == "9" || "$exit_code" == "137" ]] || \
          die "$pod terminated, but not from the requested SIGKILL (signal=$signal exit_code=$exit_code)"
        note "Old process death confirmed: pod=$pod phase=$phase signal=$signal exit_code=$exit_code"
        kube delete pod -n "$NAMESPACE" "$pod" --wait=true --timeout=120s
        ! kube get pod -n "$NAMESPACE" "$pod" >/dev/null 2>&1 || die "$pod API object still exists after deletion"
        return 0
      fi
    fi
    if (( SECONDS >= next_status )); then
      waiting "old process termination proof: pod=$pod phase=${phase:-unknown}"
      next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
    fi
    sleep 5
  done
  stuck "old process termination was not provable within ${RECOVERY_TIMEOUT_SECONDS}s for $pod"
  die "could not prove old process termination for $pod"
}

assert_distinct_nodes() {
  local left="$1" right="$2" left_node right_node
  left_node="$(kube get pod -n "$NAMESPACE" "$left" -o jsonpath='{.spec.nodeName}')"
  right_node="$(kube get pod -n "$NAMESPACE" "$right" -o jsonpath='{.spec.nodeName}')"
  [[ -n "$left_node" && -n "$right_node" ]] || die "node assignment is incomplete"
  [[ "$left_node" != "$right_node" ]] || die "$left and $right landed on the same node ($left_node)"
  note "Distinct nodes confirmed: $left=$left_node, $right=$right_node"
}

check_rdma_in_pod() {
  local pod="$1"
  note "Checking configured RDMA devices and active UCX ports in $pod"
  kube_with_timeout "$COMMAND_TIMEOUT_SECONDS" exec -n "$NAMESPACE" "$pod" -- env \
    UCX_NET_DEVICES="$UCX_NET_DEVICES" \
    MOONCAKE_IB_DEVICE="$MOONCAKE_IB_DEVICE" \
    bash -lc '
    set -euo pipefail
    test -d /dev/infiniband
    compgen -G "/dev/infiniband/*" >/dev/null

    printf "UCX_NET_DEVICES=%s\n" "$UCX_NET_DEVICES"
    printf "MOONCAKE_IB_DEVICE=%s\n" "$MOONCAKE_IB_DEVICE"

    IFS="," read -r -a ucx_entries <<<"$UCX_NET_DEVICES"
    for entry in "${ucx_entries[@]}"; do
      [[ "$entry" == "lo" ]] && continue
      device="${entry%%:*}"
      port="${entry##*:}"
      sysfs_device="$device"
      if [[ "$device" =~ ^cuda[0-9]+-(.+)$ ]]; then
        sysfs_device="${BASH_REMATCH[1]}"
        printf "UCX composite device=%s backing_ib_device=%s\n" "$device" "$sysfs_device"
      fi
      state_path="/sys/class/infiniband/${sysfs_device}/ports/${port}/state"
      test -r "$state_path"
      state=$(cat "$state_path")
      printf "UCX device=%s sysfs_device=%s port=%s state=%s\n" "$device" "$sysfs_device" "$port" "$state"
      grep -Eiq "ACTIVE|LinkUp" <<<"$state"
    done

    IFS="," read -r -a mooncake_devices <<<"$MOONCAKE_IB_DEVICE"
    for device in "${mooncake_devices[@]}"; do
      test -d "/sys/class/infiniband/${device}"
      printf "Mooncake device=%s present=true\n" "$device"
    done

    nvidia-smi -L
  ' | tee "$EVIDENCE_DIR/${pod}.rdma-preflight.txt"
}

check_runtime_compatibility() {
  local pod="$1"
  note "Recording runtime compatibility versions in $pod"
  kube_with_timeout "$COMMAND_TIMEOUT_SECONDS" exec -i -n "$NAMESPACE" "$pod" -- env \
    EXPECTED_NVIDIA_DRIVER_VERSION="$EXPECTED_NVIDIA_DRIVER_VERSION" \
    EXPECTED_TORCH_CUDA_VERSION="$EXPECTED_TORCH_CUDA_VERSION" \
    EXPECTED_NCCL_VERSION="$EXPECTED_NCCL_VERSION" \
    EXPECTED_UCX_VERSION="$EXPECTED_UCX_VERSION" \
    EXPECTED_NIXL_VERSION="$EXPECTED_NIXL_VERSION" \
    python3 - <<'PY' | tee "$EVIDENCE_DIR/${pod}.runtime-compatibility.json"
import importlib.metadata
import json
import os
import re
import shutil
import subprocess

import torch


def command_output(command: list[str]) -> str:
    if shutil.which(command[0]) is None:
        return "unavailable"
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return completed.stdout.strip()


def distribution_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "unavailable"


driver_versions = command_output(
    ["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"]
)
driver_version_set = sorted(set(filter(None, driver_versions.splitlines())))
if len(driver_version_set) != 1:
    raise SystemExit(f"expected one NVIDIA driver version, got {driver_versions!r}")

ucx_info = command_output(["ucx_info", "-v"])
ucx_match = re.search(r"\bVersion\s+(\d+\.\d+(?:\.\d+)?)\b", ucx_info)
versions = {
    "nvidia_driver": driver_version_set[0],
    "torch_cuda": torch.version.cuda or "unavailable",
    "nccl": ".".join(map(str, torch.cuda.nccl.version())),
    "ucx": ucx_match.group(1) if ucx_match else "unavailable",
    "nixl": distribution_version("nixl"),
}
expected = {
    "nvidia_driver": os.environ["EXPECTED_NVIDIA_DRIVER_VERSION"],
    "torch_cuda": os.environ["EXPECTED_TORCH_CUDA_VERSION"],
    "nccl": os.environ["EXPECTED_NCCL_VERSION"],
    "ucx": os.environ["EXPECTED_UCX_VERSION"],
    "nixl": os.environ["EXPECTED_NIXL_VERSION"],
}
for name, expected_version in expected.items():
    if expected_version and versions[name] != expected_version:
        raise SystemExit(
            f"{name} version mismatch: expected {expected_version}, got {versions[name]}"
        )

print(json.dumps(versions, sort_keys=True))
PY
}

check_cluster_capacity() {
  local nodes_json="$EVIDENCE_DIR/nodes.json"
  kube get nodes -o json >"$nodes_json"
  local eligible
  eligible="$(jq \
    --arg gpu_key "$GPU_RESOURCE_KEY" \
    --argjson gpu_count "$GPU_RESOURCE_COUNT" \
    --arg rdma_key "$RDMA_RESOURCE_KEY" \
    --argjson rdma_count "$RDMA_RESOURCE_COUNT" \
    --arg selector_key "$NODE_SELECTOR_KEY" \
    --arg selector_value "$NODE_SELECTOR_VALUE" '
      [.items[]
       | select(.spec.unschedulable != true)
       | select((.status.nodeInfo.architecture // "") == "amd64")
       | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
       | select(((.status.allocatable[$gpu_key] // "0") | tonumber) >= $gpu_count)
       | select($rdma_key == "" or
                (((.status.allocatable[$rdma_key] // "0") | tonumber) >= $rdma_count))
       | select($selector_key == "" or
                (.metadata.labels[$selector_key] // "") == $selector_value)
       | .metadata.name] | length
    ' "$nodes_json")"
  [[ "$eligible" -ge 2 ]] || die "fewer than two Ready, schedulable amd64 nodes advertise the requested GPU/RDMA resources and selector"
  note "$eligible amd64 nodes advertise the requested resources; pod scheduling will verify free capacity"
}

verify_runtime_provenance() {
  local pod="$1"
  note "Verifying pinned base image and embedded PR provenance in $pod"
  kube_with_timeout "$COMMAND_TIMEOUT_SECONDS" exec -n "$NAMESPACE" "$pod" -- env \
    EXPECTED_BASE_COMMIT="$EXPECTED_BASE_COMMIT" \
    EXPECTED_PR_SHA="$EXPECTED_PR_SHA" \
    python3 -c '
import os
from pathlib import Path
import sglang

base = os.environ.get("SGLANG_BUILD_COMMIT", "")
expected_base = os.environ["EXPECTED_BASE_COMMIT"]
assert base == expected_base, (base, expected_base)
head = os.environ.get("SGLANG_PR_COMMIT", "")
assert head == os.environ["EXPECTED_PR_SHA"], head
assert Path("/opt/pr-source/.pr-head").read_text().strip() == head
module = Path(sglang.__file__).resolve()
assert str(module).startswith("/opt/pr-source/python/"), module
print(f"base_commit={base}")
print(f"embedded_pr_commit={head}")
print(f"sglang_module={module}")
' | tee "$EVIDENCE_DIR/${pod}.provenance.txt"
}

run_upstream_preflight() {
  bool_is_true "$RUN_UPSTREAM_PREFLIGHT" || return 0
  local checker="$EVIDENCE_DIR/check_interconnect.py" rc
  if ! curl -fsSL "$UPSTREAM_CHECKER_URL" -o "$checker"; then
    warn "could not download optional upstream interconnect checker; core validation continues"
    return 0
  fi
  run_preflight_check() {
    local label="$1" output="$2"
    shift 2
    if run_with_timeout "$PREFLIGHT_TIMEOUT_SECONDS" \
      python3 "$checker" "$@" >"$output" 2>&1; then
      debug "optional preflight passed: $label"
      return 0
    else
      rc=$?
    fi
    if [[ "$rc" -eq 124 ]]; then
      stuck "optional preflight timed out after ${PREFLIGHT_TIMEOUT_SECONDS}s: $label"
    else
      warn "optional preflight failed with exit code $rc: $label; see $output"
    fi
  }
  run_preflight_check primary-node "$EVIDENCE_DIR/upstream-primary-node.json" \
    node --namespace "$NAMESPACE" --pod "$PRIMARY_POD"
  run_preflight_check primary-nixl "$EVIDENCE_DIR/upstream-primary-nixl.json" \
    nixl --namespace "$NAMESPACE" --pod "$PRIMARY_POD"
  run_preflight_check rank1-node "$EVIDENCE_DIR/upstream-rank1-node.json" \
    node --namespace "$NAMESPACE" --pod "$FAILED_POD"
}

start_port_forward() {
  kubectl --request-timeout=0 port-forward -n "$NAMESPACE" "pod/${PRIMARY_POD}" \
    "${LOCAL_PORT}:21000" >"$EVIDENCE_DIR/port-forward.log" 2>&1 &
  PF_PID=$!
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    kill -0 "$PF_PID" 2>/dev/null || die "port-forward exited; see port-forward.log"
    grep -q 'Forwarding from' "$EVIDENCE_DIR/port-forward.log" && return 0
    sleep 2
  done
  stuck "port-forward did not become ready within 60s"
  die "port-forward did not become ready"
}

wait_for_initial_server() {
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  local next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
  local slow_at=$((SECONDS + STUCK_THRESHOLD_SECONDS)) warned_slow=false
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${LOCAL_PORT}/health_generate" >/dev/null 2>&1; then
      return 0
    fi
    assert_pod_alive "$PRIMARY_POD"
    assert_pod_alive "$FAILED_POD"
    if (( SECONDS >= next_status )); then
      waiting "SGLang health endpoint on local port $LOCAL_PORT"
      next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
    fi
    if [[ "$warned_slow" == false ]] && (( SECONDS >= slow_at )); then
      warn "SGLang startup has exceeded ${STUCK_THRESHOLD_SECONDS}s; model loading may still be progressing"
      warned_slow=true
    fi
    sleep 5
  done
  stuck "SGLang health endpoint did not become ready within ${STARTUP_TIMEOUT_SECONDS}s"
  die "SGLang did not become ready within ${STARTUP_TIMEOUT_SECONDS}s"
}

generate() {
  local label="$1" routed_rank="${2:-0}"
  local payload='{"text":"The capital of France is","sampling_params":{"max_new_tokens":4,"temperature":0.0}}'
  payload="$(printf '%s' "$payload" | jq --argjson rank "$routed_rank" '. + {routed_dp_rank:$rank}')"
  curl -fsS --max-time 120 \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "http://127.0.0.1:${LOCAL_PORT}/generate" \
    | tee "$EVIDENCE_DIR/${label}.json" \
    | jq -e 'has("text") or has("output_ids")' >/dev/null
}

get_state() {
  curl -fsS --max-time 30 \
    "http://127.0.0.1:${LOCAL_PORT}/is_scaling_elastic_ep"
}

publish_stale_endpoint() {
  local runtime_instance_id="$1"
  note "Planting deliberately invalid endpoint metadata under the old operation/allocation scope"
  kube_with_timeout "$COMMAND_TIMEOUT_SECONDS" exec -n "$NAMESPACE" "$PRIMARY_POD" -- env \
    RUNTIME_INSTANCE_ID="$runtime_instance_id" \
    FAILED_ALLOCATION_ID="$FAILED_ALLOCATION_ID" \
    python3 -c '
import os
from urllib.parse import quote
import torch.distributed as dist

store = dist.TCPStore("127.0.0.1", 26555, world_size=None,
                      is_master=False, wait_for_workers=False)
prefix = (
    "elastic_ep/nixl_recovery/"
    + quote(os.environ["RUNTIME_INSTANCE_ID"], safe="") + "/0/"
    + quote("stale-operation", safe="") + "/"
    + quote(os.environ["FAILED_ALLOCATION_ID"], safe="") + "/"
)
dist.PrefixStore(prefix, store).set("NIXL_EP/1", b"stale-endpoint")
print(prefix)
' | tee "$EVIDENCE_DIR/stale-endpoint-prefix.txt"
}

wait_for_recovery_ready() {
  local deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS)) state phase
  local next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
  local slow_at=$((SECONDS + STUCK_THRESHOLD_SECONDS)) warned_slow=false
  while (( SECONDS < deadline )); do
    state="$(get_state || true)"
    if [[ -n "$state" ]]; then
      printf '%s\n' "$state" >"$EVIDENCE_DIR/recovery-state-latest.json"
      phase="$(printf '%s' "$state" | jq -r '.recovery_phase // "unknown"')"
      if [[ "$phase" == "ready" ]]; then
        printf '%s' "$state" | jq -e \
          --arg op "$OPERATION_ID" \
          --arg alloc "$REPLACEMENT_ALLOCATION_ID" \
          '.recovery_succeeded == true and
           .recovery_operation_id == $op and
           .recovery_allocation_id == $alloc and
           .recovery_rank_offset == 1 and
           .recovery_topology_generation == 0' >/dev/null
        return 0
      fi
      if [[ "$phase" == "failed" ]]; then
        printf '%s\n' "$state" >"$EVIDENCE_DIR/recovery-state-failed.json"
        if bool_is_true "$NIXL_RECOVERY_PRECONDITIONS_VERIFIED" && \
          printf '%s' "$state" | jq -e \
          --arg op "$OPERATION_ID" \
          --arg alloc "$REPLACEMENT_ALLOCATION_ID" \
          '.recovery_succeeded == false and
           .recovery_operation_id == $op and
           .recovery_allocation_id == $alloc and
           .recovery_rank_offset == 1 and
           .recovery_topology_generation == 0' >/dev/null; then
          VERDICT="NO"
          VERDICT_REASON="SGLang reported a correlated terminal failure for the expected NIXL fixed-slot recovery operation"
          die "VERDICT=NO: $VERDICT_REASON; state=$state"
        fi
        die "recovery reported failed without complete correlation to the expected operation; verdict remains INCONCLUSIVE: $state"
      fi
    fi
    assert_pod_alive "$PRIMARY_POD"
    assert_pod_alive "$REPLACEMENT_POD"
    if (( SECONDS >= next_status )); then
      waiting "recovery pending: phase=${phase:-unknown}"
      next_status=$((SECONDS + STATUS_INTERVAL_SECONDS))
    fi
    if [[ "$warned_slow" == false ]] && (( SECONDS >= slow_at )); then
      warn "recovery has remained incomplete for ${STUCK_THRESHOLD_SECONDS}s; continuing until the hard timeout"
      warned_slow=true
    fi
    sleep 5
  done
  stuck "recovery did not reach ready within ${RECOVERY_TIMEOUT_SECONDS}s"
  die "recovery did not reach ready within ${RECOVERY_TIMEOUT_SECONDS}s"
}

wait_for_recovery_observation() {
  local runtime_instance_id="$1"
  local deadline=$((SECONDS + RECOVERY_TIMEOUT_SECONDS)) state phase
  while (( SECONDS < deadline )); do
    state="$(get_state || true)"
    if [[ -n "$state" ]]; then
      printf '%s\n' "$state" >"$EVIDENCE_DIR/recovery-state-awaiting.json"
      phase="$(printf '%s' "$state" | jq -r '.recovery_phase // "unknown"')"
      if [[ "$phase" == "awaiting_recovery" ]]; then
        printf '%s' "$state" | jq -e \
          --arg instance "$runtime_instance_id" \
          '.instance_id == $instance and
           .recovery_topology_generation == 0 and
           .recovery_rank_offset == 1' >/dev/null
        return 0
      fi
      [[ "$phase" != "failed" ]] || die "membership observation failed before recovery authorization: $state"
    fi
    sleep 2
  done
  die "membership observation did not reach awaiting_recovery within ${RECOVERY_TIMEOUT_SECONDS}s"
}

main() {
  if ! mkdir -p "$EVIDENCE_DIR"; then
    printf 'FAILURE: cannot create evidence directory: %s\n' "$EVIDENCE_DIR" >&2
    return 1
  fi
  if command -v tee >/dev/null 2>&1; then
    exec > >(tee -a "$EVIDENCE_DIR/run.log") 2>&1
  else
    printf 'WARNING: tee is unavailable; output will be written only to %s/run.log\n' "$EVIDENCE_DIR" >&2
    exec >>"$EVIDENCE_DIR/run.log" 2>&1
  fi
  note "Starting Kubernetes recovery validation for PR #$PR_NUMBER at $EXPECTED_PR_SHA"
  require_command kubectl
  require_command curl
  require_command jq
  require_command python3
  require_command tar
  debug "evidence_directory=$EVIDENCE_DIR"
  debug "image=$SGLANG_IMAGE base_commit=$EXPECTED_BASE_COMMIT embedded_pr=$EXPECTED_PR_SHA"
  [[ -n "$SGLANG_IMAGE" ]] || die "SGLANG_IMAGE resolved empty"
  [[ -n "$EXPECTED_IMAGE_ID" ]] || die "EXPECTED_IMAGE_ID resolved empty"
  [[ "$GPU_RESOURCE_COUNT" == "1" ]] || die "PR #42780 Milestone 1 requires one GPU/native rank per allocation"

  validate_positive_integer GPU_RESOURCE_COUNT "$GPU_RESOURCE_COUNT"
  validate_positive_integer RDMA_RESOURCE_COUNT "$RDMA_RESOURCE_COUNT"
  validate_positive_integer COMMAND_TIMEOUT_SECONDS "$COMMAND_TIMEOUT_SECONDS"
  validate_positive_integer PREFLIGHT_TIMEOUT_SECONDS "$PREFLIGHT_TIMEOUT_SECONDS"
  validate_positive_integer STATUS_INTERVAL_SECONDS "$STATUS_INTERVAL_SECONDS"
  validate_positive_integer STUCK_THRESHOLD_SECONDS "$STUCK_THRESHOLD_SECONDS"
  validate_positive_integer RECOVERY_TIMEOUT_SECONDS "$RECOVERY_TIMEOUT_SECONDS"
  validate_positive_integer STARTUP_TIMEOUT_SECONDS "$STARTUP_TIMEOUT_SECONDS"
  validate_positive_integer CLEANUP_TIMEOUT_SECONDS "$CLEANUP_TIMEOUT_SECONDS"
  validate_positive_integer POD_ACTIVE_DEADLINE_SECONDS "$POD_ACTIVE_DEADLINE_SECONDS"
  validate_positive_integer LOCAL_PORT "$LOCAL_PORT"
  (( LOCAL_PORT <= 65535 )) || die "LOCAL_PORT must be at most 65535"
  validate_bool KEEP_RESOURCES "$KEEP_RESOURCES"
  validate_bool RUN_UPSTREAM_PREFLIGHT "$RUN_UPSTREAM_PREFLIGHT"
  validate_kubectl_timeout
  (( POD_ACTIVE_DEADLINE_SECONDS > 3 * STARTUP_TIMEOUT_SECONDS + RECOVERY_TIMEOUT_SECONDS )) || \
    die "POD_ACTIVE_DEADLINE_SECONDS must exceed three startup windows plus RECOVERY_TIMEOUT_SECONDS"
  [[ "$EXPECTED_IMAGE_ID" =~ sha256:[0-9a-fA-F]{64}$ ]] || \
    die "EXPECTED_IMAGE_ID must end in an immutable sha256 digest"
  [[ "$EXPECTED_BASE_IMAGE_DIGEST" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || \
    die "EXPECTED_BASE_IMAGE_DIGEST must be an immutable sha256 digest"
  [[ "$EXPECTED_PR_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || \
    die "EXPECTED_PR_SHA must be exactly 40 hexadecimal characters"
  [[ "$MODEL_REVISION" =~ ^[0-9a-fA-F]{40}$ ]] || \
    die "MODEL_REVISION must be exactly 40 hexadecimal characters"
  [[ "$EXPECTED_MOONCAKE_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || \
    die "EXPECTED_MOONCAKE_COMMIT must be exactly 40 hexadecimal characters"
  local value_name
  for value_name in NAMESPACE SGLANG_IMAGE MODEL MODEL_REVISION GPU_RESOURCE_KEY RDMA_RESOURCE_KEY \
    UCX_NET_DEVICES UCX_TLS MOONCAKE_IB_DEVICE NODE_SELECTOR_KEY NODE_SELECTOR_VALUE \
    HF_TOKEN_SECRET_NAME HF_CACHE_PVC IMAGE_PULL_SECRET EXPECTED_IMAGE_ID \
    EXPECTED_BASE_IMAGE_DIGEST EXPECTED_MOONCAKE_COMMIT KUBECTL_REQUEST_TIMEOUT \
    EVIDENCE_DIR EXPECTED_NVIDIA_DRIVER_VERSION EXPECTED_TORCH_CUDA_VERSION \
    EXPECTED_NCCL_VERSION EXPECTED_UCX_VERSION EXPECTED_NIXL_VERSION; do
    validate_scalar "$value_name" "${!value_name}"
  done
  validate_required_rdma_configuration
  if [[ -n "$NODE_SELECTOR_KEY" && -z "$NODE_SELECTOR_VALUE" ]]; then
    die "NODE_SELECTOR_VALUE is required when NODE_SELECTOR_KEY is set"
  fi

  note "RDMA configuration: resource=${RDMA_RESOURCE_KEY} count=${RDMA_RESOURCE_COUNT} UCX_NET_DEVICES=${UCX_NET_DEVICES} UCX_TLS=${UCX_TLS} MOONCAKE_IB_DEVICE=${MOONCAKE_IB_DEVICE}"

  if ! kube get namespace "$NAMESPACE" >/dev/null 2>&1; then
    require_permission create namespaces cluster
    require_permission delete namespaces cluster
    kube create namespace "$NAMESPACE"
    NAMESPACE_CREATED_BY_RUN=true
  fi
  check_prerequisite_permissions
  check_cluster_capacity
  note "Validation uses one digest-pinned image containing base $EXPECTED_BASE_COMMIT, Mooncake $EXPECTED_MOONCAKE_COMMIT, and PR $EXPECTED_PR_SHA"
  warn "Cost bound: at most two one-GPU Pods run concurrently; each has activeDeadlineSeconds=$POD_ACTIVE_DEADLINE_SECONDS"
  mark_stage setup complete

  cat <<EOF | kube apply -f -
apiVersion: v1
kind: Service
metadata:
  name: "${SERVICE}"
  namespace: "${NAMESPACE}"
  labels:
    app.kubernetes.io/name: "${APP}"
    app.kubernetes.io/instance: "${RUN_ID}"
spec:
  selector:
    app.kubernetes.io/instance: "${RUN_ID}"
    recovery-role: primary
  ports:
    - name: dist
      port: 26555
      targetPort: 26555
    - name: http
      port: 21000
      targetPort: 21000
EOF

  {
    render_common_pod "$PRIMARY_POD" primary 0 21000 "$PRIMARY_ALLOCATION_ID" auto 0
    echo '---'
    render_common_pod "$FAILED_POD" rank1 1 22000 "$FAILED_ALLOCATION_ID" auto 1
  } | tee "$EVIDENCE_DIR/initial-pods.yaml" | kube apply -f -

  mark_stage initial-pods submitted
  wait_for_pod_running "$PRIMARY_POD"
  wait_for_pod_running "$FAILED_POD"
  : >"$EVIDENCE_DIR/image-ids.txt"
  verify_pod_image "$PRIMARY_POD"
  verify_pod_image "$FAILED_POD"
  verify_runtime_provenance "$PRIMARY_POD"
  verify_runtime_provenance "$FAILED_POD"
  assert_distinct_nodes "$PRIMARY_POD" "$FAILED_POD"
  check_rdma_in_pod "$PRIMARY_POD"
  check_rdma_in_pod "$FAILED_POD"
  check_runtime_compatibility "$PRIMARY_POD"
  check_runtime_compatibility "$FAILED_POD"
  run_upstream_preflight
  mark_stage initial-pods ready

  start_port_forward
  wait_for_initial_server
  note "Confirming PR feature presence"
  kube_with_timeout "$COMMAND_TIMEOUT_SECONDS" exec -n "$NAMESPACE" "$PRIMARY_POD" -- python3 -c \
    'from sglang.srt.layers.moe.token_dispatcher.nixl import NixlEPBuffer; assert hasattr(NixlEPBuffer,"prepare_recovery"); assert hasattr(NixlEPBuffer,"connect_recovery")'

  note "Baseline inference"
  generate baseline
  get_state | tee "$EVIDENCE_DIR/state-before-failure.json" | jq -e \
    '.allocation_width == 1 and .effective_ep_size == 2 and .recovery_phase == "idle"' >/dev/null
  local runtime_instance_id
  runtime_instance_id="$(jq -r '.instance_id' "$EVIDENCE_DIR/state-before-failure.json")"
  [[ -n "$runtime_instance_id" && "$runtime_instance_id" != "null" ]] || die "runtime instance ID is missing"
  mark_stage baseline complete

  note "Stopping and fencing non-primary allocation $FAILED_POD"
  kube logs -n "$NAMESPACE" "$FAILED_POD" --timestamps \
    >"$EVIDENCE_DIR/${FAILED_POD}.before-deletion.log" 2>&1 || true
  kube describe pod -n "$NAMESPACE" "$FAILED_POD" \
    >"$EVIDENCE_DIR/${FAILED_POD}.before-deletion.describe.txt" 2>&1 || true
  kill_and_confirm_failed_allocation "$FAILED_POD"
  mark_stage failed-allocation deleted

  [[ -n "$FAILED_POD_UID" ]] || die "failed allocation incarnation is missing"
  note "Publishing correlated failed-membership observation for incarnation $FAILED_POD_UID"
  curl -fsS --max-time 60 \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc \
      --arg instance "$runtime_instance_id" \
      --arg incarnation "$FAILED_POD_UID" \
      '{runtime_instance_id:$instance,topology_generation:0,rank:1,
        failed_allocation_incarnation:$incarnation,membership_epoch:1}')" \
    "http://127.0.0.1:${LOCAL_PORT}/observe_elastic_ep_membership" \
    | tee "$EVIDENCE_DIR/membership-observation.json" | jq -e '.observation_key' >/dev/null
  wait_for_recovery_observation "$runtime_instance_id"

  note "Authorizing fixed-slot recovery operation $OPERATION_ID"
  curl -fsS --max-time 60 \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc \
      --arg op "$OPERATION_ID" \
      --arg alloc "$REPLACEMENT_ALLOCATION_ID" \
      --arg incarnation "$FAILED_POD_UID" \
      '{operation_id:$op,topology_generation:0,allocation_id:$alloc,rank_offset:1,
        failed_allocation_incarnation:$incarnation}')" \
    "http://127.0.0.1:${LOCAL_PORT}/recover_elastic_ep" \
    | tee "$EVIDENCE_DIR/recovery-submit.json" | jq -e \
      --arg op "$OPERATION_ID" '.operation_id == $op and .recovery_phase == "restoring"' >/dev/null
  mark_stage recovery-authorized complete

  publish_stale_endpoint "$runtime_instance_id"

  note "Launching replacement allocation for global EP rank 1"
  render_common_pod "$REPLACEMENT_POD" replacement 1 22000 \
    "$REPLACEMENT_ALLOCATION_ID" recover \
    | tee "$EVIDENCE_DIR/replacement-pod.yaml" | kube apply -f -
  wait_for_pod_running "$REPLACEMENT_POD"
  REPLACEMENT_POD_UID="$(kube get pod -n "$NAMESPACE" "$REPLACEMENT_POD" \
    -o jsonpath='{.metadata.uid}')"
  [[ -n "$REPLACEMENT_POD_UID" ]] || die "replacement allocation pod has no Kubernetes UID"
  [[ "$REPLACEMENT_POD_UID" != "$FAILED_POD_UID" ]] || \
    die "replacement allocation reused the failed pod UID: $REPLACEMENT_POD_UID"
  printf '%s\n' "$REPLACEMENT_POD_UID" >"$EVIDENCE_DIR/${REPLACEMENT_POD}.uid"
  note "Verified distinct replacement identity: old_uid=$FAILED_POD_UID new_uid=$REPLACEMENT_POD_UID"
  verify_pod_image "$REPLACEMENT_POD"
  verify_runtime_provenance "$REPLACEMENT_POD"
  assert_distinct_nodes "$PRIMARY_POD" "$REPLACEMENT_POD"
  check_rdma_in_pod "$REPLACEMENT_POD"
  check_runtime_compatibility "$REPLACEMENT_POD"
  mark_stage replacement-pod ready

  NIXL_RECOVERY_PRECONDITIONS_VERIFIED=true
  note "NIXL recovery preconditions verified; a correlated terminal SGLang failure can now produce VERDICT=NO"
  wait_for_recovery_ready
  mark_stage recovery-ready complete
  note "Routing inference explicitly through recovered DP/EP rank 1"
  generate recovered-rank1 1
  get_state | tee "$EVIDENCE_DIR/state-final.json" | jq -e \
    --arg op "$OPERATION_ID" \
    --arg alloc "$REPLACEMENT_ALLOCATION_ID" \
    '.allocation_width == 1 and .effective_ep_size == 2 and
     .recovery_phase == "ready" and .recovery_succeeded == true and
     .recovery_operation_id == $op and .recovery_allocation_id == $alloc and
     .recovery_rank_offset == 1 and .recovery_topology_generation == 0' >/dev/null

  TEST_SUCCEEDED=true
  VERDICT="YES"
  VERDICT_REASON="correlated fixed-slot recovery reached ready and inference completed through recovered rank 1"
  succeed "VERDICT=YES: $VERDICT_REASON"
  mark_stage validation complete
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap on_err ERR
  trap 'on_signal HUP 129' HUP
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  trap on_exit EXIT
  main "$@"
fi
