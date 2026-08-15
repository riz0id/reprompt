"""Argument parsing and process start."""

import argparse
import sys

from reprompt import __version__
from reprompt.config import BackendConfig, RepromptConfig, load_config
from reprompt.hook import load_hook_function
from reprompt.lift import lift_record_file
from reprompt.proxy import build_proxy, run_proxy
from reprompt.transformers import rewrite as default_rewrite


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="reprompt",
        description="MCP tool proxy that intercepts, rewrites, and reports tool calls.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("run", help="Start the proxy.")
    run.add_argument("--config", metavar="PATH", help="Path to the configuration file.")
    run.add_argument(
        "backend",
        nargs=argparse.REMAINDER,
        help="A stdio backend command, given after '--'.",
    )

    check = subparsers.add_parser(
        "check", help="Validate the configuration file and exit."
    )
    check.add_argument(
        "--config",
        metavar="PATH",
        required=True,
        help="Path to the configuration file.",
    )

    lift = subparsers.add_parser(
        "lift", help="Lift recorded Bash commands into a #lang rash module."
    )
    lift.add_argument("record", metavar="RECORD", help="Path to a record.jsonl file.")
    lift.add_argument(
        "-o",
        "--output",
        metavar="PATH",
        help="Write the module here (default: stdout).",
    )

    subparsers.add_parser("version", help="Show the version and exit.")
    return parser


def _run_config(
    args: argparse.Namespace, parser: argparse.ArgumentParser
) -> RepromptConfig:
    backend = list(args.backend)
    if backend and backend[0] == "--":
        backend = backend[1:]

    if args.config and backend:
        parser.error("give --config or a backend command, not both")
    if args.config:
        return load_config(args.config)
    if backend:
        return RepromptConfig(backends={"backend": BackendConfig(command=backend)})
    parser.error("give --config PATH or a backend command after '--'")
    raise AssertionError("unreachable")


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "version":
        print(__version__)
        return 0

    if args.command == "check":
        try:
            load_config(args.config)
        except Exception as error:
            print(f"reprompt: invalid configuration: {error}", file=sys.stderr)
            return 1
        print(f"{args.config}: OK")
        return 0

    if args.command == "lift":
        try:
            module_text = lift_record_file(args.record)
        except (OSError, ValueError) as error:
            print(f"reprompt: {error}", file=sys.stderr)
            return 1
        if args.output:
            with open(args.output, "w", encoding="utf-8") as output_file:
                output_file.write(module_text)
        else:
            sys.stdout.write(module_text)
        return 0

    # args.command == "run"
    try:
        config = _run_config(args, parser)
        # With no rewrite named in the config, fall back to the built-in
        # hook that loads every Rash transformer in reprompt.transformers.
        rewrite = (
            load_hook_function(config.rewrite)
            if config.rewrite is not None
            else default_rewrite
        )
        meta_fn = load_hook_function(config.meta) if config.meta is not None else None
    except Exception as error:
        print(f"reprompt: {error}", file=sys.stderr)
        return 1

    proxy = build_proxy(config, rewrite, meta_fn, config.record)
    run_proxy(proxy, config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
