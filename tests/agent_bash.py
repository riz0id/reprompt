"""MCP agent for the bash-metadata integration test.

Runs inside the guest as the ``agent`` user. The model is Qwen3-4B-Instruct
served by llama-server on 127.0.0.1:8080 (OpenAI-compatible chat API with
tool calling). The tools come from the reprompt proxy on the HOST, reached
through the QEMU user-network gateway (10.0.2.2:8383).

The agent presents each MCP tool result to the model as JSON that includes
the result content, the isError flag, and the _meta field verbatim.

The conversation is one continuous message history with exactly two user
prompts: run an echo command with the Bash tool, then write foobar.txt with
the Write tool. The host-side meta hook tags only the Bash call with the
BashCommand metadata; all pass/fail artifacts land on the host, and this
agent only prints a trace.
"""

import asyncio
import json
import os
import urllib.request
from typing import Any

from fastmcp import Client

MCP_URL = os.environ.get("REPROMPT_MCP_URL", "http://10.0.2.2:8383/mcp")
LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080/v1/chat/completions")

SYSTEM_PROMPT = (
    "You are a precise assistant with access to tools. When a task needs a "
    "tool, call the tool. Tool results are JSON objects that contain the "
    "fields content, isError, and _meta; read all of them."
)

PROMPT_1 = (
    'Use the Bash tool to run this exact command: echo "hello world!" '
    "Use no other tool."
)

PROMPT_2 = (
    "Use the Write tool to create the file foobar.txt with exactly the "
    "content fizz and no trailing newline. Use no other tool."
)

Message = dict[str, Any]


def chat(messages: list[Message], tools: list[dict[str, Any]]) -> Message:
    """One chat completion against the local llama-server."""
    body = json.dumps(
        {
            "model": "qwen3",
            "messages": messages,
            "tools": tools,
            "temperature": 0,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        LLAMA_URL, data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=1200) as response:
        payload = json.loads(response.read())
    message: Message = payload["choices"][0]["message"]
    return message


async def run_prompt(
    client: Client, messages: list[Message], tools: list[dict[str, Any]], prompt: str
) -> None:
    """Add one user prompt and run the tool loop until the model stops."""
    messages.append({"role": "user", "content": prompt})
    for _ in range(8):
        reply = chat(messages, tools)
        messages.append(reply)
        calls = reply.get("tool_calls") or []
        if not calls:
            break
        for call in calls:
            function = call.get("function") or {}
            name = str(function.get("name"))
            try:
                arguments = json.loads(function.get("arguments") or "{}")
            except json.JSONDecodeError:
                arguments = {}
            print(
                "AGENT tool_call: " + name + " " + json.dumps(arguments),
                flush=True,
            )
            result = await client.call_tool_mcp(name, arguments)
            texts = [
                text
                for block in result.content
                if isinstance(text := getattr(block, "text", None), str)
            ]
            surfaced = {
                "content": "\n".join(texts),
                "isError": bool(result.isError),
                "_meta": result.meta,
            }
            print(
                "AGENT tool_result: " + json.dumps(surfaced, default=str)[:500],
                flush=True,
            )
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call.get("id") or name,
                    "content": json.dumps(surfaced, default=str),
                }
            )
    final = next(
        (
            m.get("content")
            for m in reversed(messages)
            if m.get("role") == "assistant" and m.get("content")
        ),
        "",
    )
    print("AGENT assistant: " + str(final)[:500], flush=True)


async def main() -> None:
    async with Client(MCP_URL) as client:
        mcp_tools = await client.list_tools()
        tools = [
            {
                "type": "function",
                "function": {
                    "name": tool.name,
                    "description": tool.description or "",
                    "parameters": tool.inputSchema,
                },
            }
            for tool in mcp_tools
        ]
        print(
            "AGENT tools: " + json.dumps([tool.name for tool in mcp_tools]),
            flush=True,
        )
        messages: list[Message] = [{"role": "system", "content": SYSTEM_PROMPT}]
        await run_prompt(client, messages, tools, PROMPT_1)
        await run_prompt(client, messages, tools, PROMPT_2)


if __name__ == "__main__":
    asyncio.run(main())
