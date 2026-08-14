"""Configuration schema and validation."""

from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, model_validator


class ListenConfig(BaseModel):
    """The frontend transport that the proxy listens on."""

    transport: Literal["stdio", "http"] = "stdio"
    host: str = "127.0.0.1"
    port: int = 8000


class BackendConfig(BaseModel):
    """One backend MCP server: a stdio command or a remote URL."""

    command: list[str] | None = None
    url: str | None = None

    @model_validator(mode="after")
    def _exactly_one_target(self) -> "BackendConfig":
        if (self.command is None) == (self.url is None):
            raise ValueError("a backend needs exactly one of 'command' or 'url'")
        if self.command is not None and not self.command:
            raise ValueError("'command' must not be empty")
        return self


class RepromptConfig(BaseModel):
    """The reprompt.yaml schema."""

    listen: ListenConfig = ListenConfig()
    backends: dict[str, BackendConfig]
    rewrite: str | None = None
    meta: str | None = None
    record: str | None = None

    @model_validator(mode="after")
    def _validate(self) -> "RepromptConfig":
        if not self.backends:
            raise ValueError("at least one backend is required")
        if self.rewrite is not None and ":" not in self.rewrite:
            raise ValueError("'rewrite' must have the form 'module:function'")
        if self.meta is not None and ":" not in self.meta:
            raise ValueError("'meta' must have the form 'module:function'")
        return self


def load_config(path: str | Path) -> RepromptConfig:
    """Read and validate a configuration file."""
    data = yaml.safe_load(Path(path).read_text())
    if not isinstance(data, dict):
        raise ValueError(f"{path}: the configuration must be a YAML mapping")
    return RepromptConfig.model_validate(data)
