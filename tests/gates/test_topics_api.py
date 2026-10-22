"""Topics HTTP API and the session topic binding (topics/ARCHITECTURE.md)."""

from __future__ import annotations

import httpx

from agent_core.api import create_app
from agent_core.bootstrap import build
from tests.contract.support import principal
from tests.integration.m2_support import memory_settings


async def test_topics_are_created_listed_sealed_and_bind_sessions() -> None:
    owner = principal().model_copy(update={"scopes": {"session.read", "session.write"}})
    async with build(settings=memory_settings(), storage="memory", principal=owner) as app:
        api = create_app(
            app.services, app.settings, app.principal, app.new_request_id, app.readiness_probe
        )
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=api, client=("127.0.0.1", 1234)),
            base_url="http://localhost",
        ) as client:
            created = await client.post("/v1/topics", json={"id": "garden", "name": "Garden"})
            assert created.status_code == 201, created.text
            assert created.json()["sealed"] is False
            assert (
                await client.post("/v1/topics", json={"id": "garden", "name": "x"})
            ).status_code == 409
            assert (
                await client.post("/v1/topics", json={"id": "core", "name": "x"})
            ).status_code == 400
            sealed = await client.patch("/v1/topics/garden", json={"sealed": True})
            assert sealed.status_code == 200 and sealed.json()["sealed"] is True
            listed = await client.get("/v1/topics")
            assert [row["id"] for row in listed.json()["items"]] == ["garden"]

            bound = await client.post(
                "/v1/sessions", json={"agent_id": "general", "topic_id": "garden"}
            )
            assert bound.status_code == 201, bound.text
            assert bound.json()["topic_id"] == "garden"
            unknown = await client.post(
                "/v1/sessions", json={"agent_id": "general", "topic_id": "nowhere"}
            )
            assert unknown.status_code == 404
            core = await client.post("/v1/sessions", json={"agent_id": "general"})
            assert core.status_code == 201 and core.json()["topic_id"] is None
