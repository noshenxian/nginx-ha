# KP-HA OpenResty Load Balancer Release

## Contents

- OpenResty gateway with weighted round-robin load balancing.
- Cookie/Header/IP based session stickiness.
- Active health checks and passive failover.
- Authenticated `/status` endpoint.
- `/healthz` endpoint.
- WebSocket forwarding.
- `Server: KP-HA` response header.
- Docker Compose examples for generic backends and two Tomcat instances.
- Integration tests for local OpenResty and Docker Tomcat examples.
- Embedded snippets for existing OpenResty or nginx-with-lua deployments.
- Plain nginx fallback snippet with reduced feature set.

## Required Configuration

Copy `.env.example` to `.env` and set:

- `BACKEND_UPSTREAMS`
- `API_GATEWAY_SECRET`
- `GATEWAY_BIND`

`API_GATEWAY_SECRET` is required. Do not use the example value in production.

## Quick Start

```bash
cp .env.example .env
sh ./start.sh
```

Tomcat demo:

```bash
docker compose -f docker-compose.tomcat.yml up -d --build
curl http://127.0.0.1:18090/
```

## Verification

```bash
scripts/render_config.sh
scripts/validate_config.sh
tests/test_gateway.sh
tests/test_tomcat_docker.sh
```
