# wms-be (backend)

- Remote: https://github.com/chinnisasi/WMS-BE.git
- Local path: `workspace/core/backend/wms-be`
- Role: backend
- Default branch: main

Durable notes about this repo (architecture, conventions, what it exposes to `wms-fe`) go here. Repo-local operational docs (setup, scripts, etc.) stay inside the repo itself.

## Interface Contract (what this repo provides to `wms-fe`)

Keep this current whenever a cross-repo change lands — this is what lets an agent catch "this backend change breaks the frontend" *before* making the change, not after.

- API base path / version exposed:
- Endpoints offered (path, method, request/response shape or link to OpenAPI spec):
- Shared types/DTOs (source of truth, how the frontend consumes them):
- Auth mechanism offered:
- Breaking-change policy (deprecation window, versioning approach):