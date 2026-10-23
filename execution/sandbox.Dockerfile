FROM python:3.12-alpine@sha256:b658b05ce9c4eb97ec6fc19424818a1f31993659c2b505a532f470e83807815d

RUN mkdir -p /opt/agent/agent_core/execution
COPY src/agent_core/__init__.py /opt/agent/agent_core/__init__.py
COPY src/agent_core/execution/__init__.py /opt/agent/agent_core/execution/__init__.py
COPY src/agent_core/execution/egress_core.py /opt/agent/agent_core/execution/egress_core.py
COPY src/agent_core/execution/proxy.py /opt/agent/agent_core/execution/proxy.py
COPY src/agent_core/execution/bridge_relay.py /opt/agent/agent_core/execution/bridge_relay.py
RUN mkdir -p /workspace && chown nobody:nobody /workspace && chmod 0700 /workspace
ENV PYTHONPATH=/opt/agent
WORKDIR /workspace
USER nobody:nobody
