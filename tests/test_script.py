# The Python test-driver script for the reprompt integration test.
# tests/integration.nix loads this file with builtins.readFile and appends
# run_test(machine, subtest). The NixOS test driver supplies the `machine` and
# `subtest` objects at run time; they enter this module only as function
# parameters, so the module type-checks against the standard library alone.
#
# The guest runs a fully local model stack: llama-server with
# Qwen3-4B-Instruct, driven by tests/agent.py. The agent connects to the
# reprompt proxy on the HOST (gateway 10.0.2.2:8383) and issues exactly two
# prompts: write hello_world.txt, then recall the random number from the
# earlier tool response _meta and write it to recalled.txt. All pass/fail
# artifacts are host files; run.sh checks them after the VM has closed. This
# script asserts nothing about the number — it only drives the agent and
# relays its trace to the driver log.
from contextlib import AbstractContextManager
from typing import Any, Callable

Subtest = Callable[[str], AbstractContextManager[None]]


def run_test(machine: Any, subtest: Subtest) -> None:
    """Boot the guest, wait for the model server, run the agent once."""
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("llama.service")
    machine.wait_for_open_port(8080)

    # The model (~2.4 GiB over the shared store) takes a while to load;
    # llama-server answers /health with 200 only when it is ready.
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:8080/health", timeout=1800)

    with subtest("the agent runs both prompts through the host proxy"):
        output = machine.succeed(
            "su - agent -c 'python /etc/reprompt/agent.py'",
            timeout=3600,
        )
        # Relay the agent trace to the host-side driver log.
        for line in output.splitlines():
            print("GUEST " + line, flush=True)
