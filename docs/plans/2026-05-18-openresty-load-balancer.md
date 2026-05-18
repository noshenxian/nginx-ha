# OpenResty Load Balancer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a project-local OpenResty load balancer with session stickiness, active health checks, metrics, config rendering, Docker runtime, and integration tests.

**Architecture:** `scripts/render_config.sh` renders environment-driven OpenResty configuration into `build/`. Nginx routes all proxy traffic through `lua/balancer.lua`, which uses `ngx.balancer` and shared dictionaries for upstream state, session binding, health status, and metrics. `lua/healthcheck.lua` runs in worker timers and updates shared health state that the balancer honors.

**Tech Stack:** OpenResty, nginx config templates, Lua modules, POSIX shell scripts, Docker Compose, shell integration tests.

### Task 1: Integration Test Harness

**Files:**
- Create: `tests/test_gateway.sh`
- Create: `tests/fixtures/backend.py`
- Create: `scripts/render_config.sh`
- Create: `scripts/validate_config.sh`

**Steps:**
1. Write a failing shell test that expects config rendering, nginx config validation, health endpoint, sticky cookie behavior, failover, status auth, and WebSocket upgrade support.
2. Run `tests/test_gateway.sh` and confirm it fails because implementation files are missing.
3. Add only the minimum scripts needed for the test to call real project commands.

### Task 2: OpenResty Gateway Core

**Files:**
- Create: `conf/nginx.conf.template`
- Create: `lua/balancer.lua`
- Create: `lua/healthcheck.lua`
- Create: `lua/metrics.lua`
- Create: `lua/request_id.lua`

**Steps:**
1. Make config rendering produce `build/nginx.conf`.
2. Implement upstream parsing, weighted round-robin, sticky cookie/header/ip modes, and unhealthy upstream avoidance.
3. Implement active health checks and passive failure accounting.
4. Expose `/healthz`, authenticated `/status`, and proxy all other paths.

### Task 3: Runtime Packaging and Docs

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.yml`
- Create: `start.sh`
- Create: `README.md`

**Steps:**
1. Package OpenResty runtime with Lua files, config templates, scripts, and tests.
2. Document environment variables, sticky behavior, health checks, metrics, and local commands.
3. Run render, validation, and integration tests.
