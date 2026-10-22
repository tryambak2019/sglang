import hashlib
import os
import subprocess
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from urllib.parse import quote

import torch.distributed as dist


class TestNixlEndpointScopeProbe(unittest.TestCase):
    def setUp(self):
        self.store = dist.TCPStore(
            "127.0.0.1",
            0,
            world_size=None,
            is_master=True,
            wait_for_workers=False,
            timeout=timedelta(seconds=2),
        )

    def test_probe_uses_durable_markers_after_endpoint_cleanup(self):
        runtime_instance_id = "runtime/1"
        operation_id = "recover/1"
        failed_allocation_id = "failed/1"
        replacement_allocation_id = "replacement/1"
        base_prefix = (
            f"elastic_ep/nixl_recovery/{quote(runtime_instance_id, safe='')}/0/"
        )
        stale_prefix = (
            base_prefix
            + f"{quote('stale-operation', safe='')}/"
            + f"{quote(failed_allocation_id, safe='')}/"
        )
        current_prefix = (
            base_prefix
            + f"{quote(operation_id, safe='')}/"
            + f"{quote(replacement_allocation_id, safe='')}/"
        )
        stale_store = dist.PrefixStore(stale_prefix, self.store)
        current_store = dist.PrefixStore(current_prefix, self.store)

        poison = b"stale-endpoint"
        stale_store.set("NIXL_EP/1", poison)

        # NIXL publishes metadata only while connect_ranks() consumes it, then
        # removes the local key before returning to SGLang.
        current_store.set("NIXL_EP/1", b"current-endpoint")
        self.assertTrue(current_store.check(["NIXL_EP/1"]))
        self.assertTrue(current_store.delete_key("NIXL_EP/1"))

        # SGLang publishes these only after scoped NIXL connection succeeds.
        current_store.set("connected/0", b"1")
        current_store.set("connected/1", b"1")

        self.assertTrue(stale_store.check(["NIXL_EP/1"]))
        self.assertEqual(stale_store.get("NIXL_EP/1"), poison)
        self.assertFalse(current_store.check(["NIXL_EP/1"]))
        for key in ("connected/0", "connected/1"):
            self.assertTrue(current_store.check([key]))
            self.assertEqual(
                hashlib.sha256(current_store.get(key)).hexdigest(),
                hashlib.sha256(b"1").hexdigest(),
            )

        self.assertNotEqual(
            hashlib.sha256((stale_prefix + "NIXL_EP/1").encode()).hexdigest(),
            hashlib.sha256((current_prefix + "NIXL_EP/1").encode()).hexdigest(),
        )

    def test_inference_runs_when_scope_probe_fails(self):
        script = (
            Path(__file__).resolve().parents[4]
            / "validation"
            / "run_nixl_fixed_slot_recovery_k8s.sh"
        )
        with tempfile.TemporaryDirectory() as evidence_dir:
            env = os.environ.copy()
            env["EVIDENCE_DIR"] = evidence_dir
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
source "$1"
capture_endpoint_scope_proof() { return 1; }
generate() { inference_called=true; return 0; }
record_recovered_rank_inference_result() { return 0; }
mark_stage() { return 0; }
note() { return 0; }
warn() { return 0; }
inference_called=false
if collect_post_recovery_evidence runtime-1; then
  exit 10
fi
[[ "$inference_called" == true ]]
[[ "$ENDPOINT_SCOPE_PROVED" == false ]]
[[ "$RECOVERED_RANK_INFERENCE_SUCCEEDED" == true ]]
""",
                    "bash",
                    str(script),
                ],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
