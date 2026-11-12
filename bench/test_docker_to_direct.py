"""Tests for the 'docker run' to direct execution converter (no GPU needed)."""
import subprocess
from pathlib import Path

import pytest

import docker_to_direct as conv

EXAMPLE = r'''#!/usr/bin/env bash
set -euo pipefail
docker run -d -e HF_HUB_OFFLINE=1 --name "$NAME" --init --gpus "\"device=$GPUS\"" \
  -v "$HF_CACHE":/root/.cache/huggingface \
  -e VLLM_PLUGINS='' \
  -e CUDA_ARCH_LIST='7.5 8.0 12.0' \
  `# inherited from the image or the printing environment` \
  -e NCCL_P2P_LEVEL=SYS \
  "$IMAGE" \
  vllm serve org/model \
    --additional-config '{"a":"b"}' \
    --port "$PORT" \
    --tensor-parallel-size 4
'''

HERE = Path(__file__).resolve().parent


def test_extracts_environment_variables_with_empty_values_and_spaces():
    envs, _ = conv.extract(EXAMPLE)
    assert envs == {"HF_HUB_OFFLINE": "1", "VLLM_PLUGINS": "", "CUDA_ARCH_LIST": "7.5 8.0 12.0",
                    "NCCL_P2P_LEVEL": "SYS"}


def test_extracts_command_after_image():
    _, cmd = conv.extract(EXAMPLE)
    assert cmd == ["vllm", "serve", "org/model", "--additional-config", '{"a":"b"}', "--port", "$PORT",
                   "--tensor-parallel-size", "4"]


def test_generated_script_keeps_port_and_gpus_as_variables():
    script = conv.generate(EXAMPLE)
    assert '"$PORT"' in script
    assert 'CUDA_VISIBLE_DEVICES="$GPUS"' in script
    assert "--additional-config '{\"a\":\"b\"}'" in script


def test_generated_script_is_valid_bash(tmp_path):
    target = tmp_path / "s.sh"
    target.write_text(conv.generate(EXAMPLE))
    assert subprocess.run(["bash", "-n", str(target)]).returncode == 0


def test_fails_loudly_without_image():
    with pytest.raises(conv.InvalidScript):
        conv.extract("docker run -d -e A=1 \\\n  vllm serve x\n")


def test_converts_the_real_r1_script():
    real = HERE / "server-vllm.sh"
    envs, cmd = conv.extract(real.read_text())
    assert envs["VLLM_PCIE_ALLREDUCE_BACKEND"] == "b12x"
    assert cmd[:2] == ["vllm", "serve"]
    assert "--speculative-config" in cmd


@pytest.mark.parametrize("docker_script, direct_script",
                         [("server-vllm.sh", "server-vllm-direct.sh"),
                          ("server-vllm-dcp1.sh", "server-vllm-dcp1-direct.sh")])
def test_committed_direct_scripts_match_the_generator(docker_script, direct_script):
    assert (HERE / direct_script).read_text() == conv.generate((HERE / docker_script).read_text())
