"""FastMCP proxy construction (create_proxy) and transports."""

from typing import Any

from fastmcp.server import create_proxy
from fastmcp.server.providers.proxy import FastMCPProxy

from reprompt.config import RepromptConfig
from reprompt.hook import MetaFn, RewriteFn
from reprompt.middleware import RepromptMiddleware


def build_proxy(
    config: RepromptConfig,
    rewrite: RewriteFn | None,
    meta_fn: MetaFn | None = None,
    record_path: str | None = None,
) -> FastMCPProxy:
    """Create the proxy server for the configured backends."""
    servers: dict[str, dict[str, Any]] = {}
    for name, backend in config.backends.items():
        if backend.command is not None:
            servers[name] = {"command": backend.command[0], "args": backend.command[1:]}
        else:
            servers[name] = {"url": backend.url}

    proxy = create_proxy({"mcpServers": servers}, name="reprompt")
    if rewrite is not None or meta_fn is not None or record_path is not None:
        effective_rewrite: RewriteFn = rewrite if rewrite is not None else _identity
        proxy.add_middleware(
            RepromptMiddleware(effective_rewrite, meta_fn, record_path)
        )
    return proxy


def _identity(body: dict[str, Any]) -> dict[str, Any]:
    """A rewrite that changes nothing, for the meta-only configuration."""
    return body


def run_proxy(proxy: FastMCPProxy, config: RepromptConfig) -> None:
    """Run the proxy on the configured frontend transport."""
    listen = config.listen
    if listen.transport == "http":
        proxy.run(transport="http", host=listen.host, port=listen.port)
    else:
        proxy.run(transport="stdio")
