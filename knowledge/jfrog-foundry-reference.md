<!-- scope: jfrog, artifactory, registry, docker, repository, repositories, virtual repo, local repo, foundry, hosted agent, hosted agents, responses protocol, responses, byor, bring your own registry, pull token, token exchange, oauth, oidc, entra, audience, issuer, identity mapping, connection, connections, sku, cpu, memory, version, versions, latest, endpoint, protocol, readiness, liveness, healthz, echo mode, model mode, azapi, data plane -->
# JFrog and Foundry reference notes (condensed)

Written 2026-10-10. This covers only what the two repositories document or implement, not general product behavior. If a question goes beyond it, say it is not covered. IDs are redacted on purpose.

## The bring-your-own-registry pull path

A Foundry hosted agent runs a container image. In this project the image is stored in a private JFrog registry instead of Azure Container Registry. Two different identities are involved and they are independent:

- Push side: GitHub Actions authenticates to JFrog with GitHub OIDC (no stored credential) and pushes the image.
- Pull side: the Foundry project's managed identity gets an Entra token, exchanges it with JFrog for a short-lived pull token (OAuth token exchange), and pulls the image. The agent never holds a registry credential.

The pull side is configured by a Foundry project connection of type `registry_connection` with mode `oauth_token_exchange`, owned by the foundation repo. The hosted agent references the connection by name. The deploy workflow re-checks the live connection (target, type and mode) before Terraform runs and fails if it does not match.

## Registry connection

- The active connection is `jfrog-registry`, created with AzAPI in the foundation Terraform. A second connection, `legacy_registry`, is still defined there and protected by `prevent_destroy`.
- Its target is the JFrog base URL (`https://trialndswdc.jfrog.io`), published in the contract as `JF_URL` without a trailing slash.
- The token exchange settings are published as `REGISTRY_TOKEN_AUDIENCE`, `REGISTRY_TOKEN_ENDPOINT` and `REGISTRY_OIDC_PROVIDER_NAME`. The agent workflow does not need them.
- If Terraform ever wants to create this connection while it already exists, the state is missing it: import it, do not apply.

## JFrog side (done by a JFrog administrator, outside Terraform)

1. Entra integration for the Foundry project identity: issuer is the tenant's Entra v2.0 URL, the audience matches the token audience used by the connection, and an identity mapping ties the project managed identity (the contract's principal ID) to a user or group with read permission on the Docker repository. The provider name must match the connection's OIDC provider name (`oidc-byor`).
2. GitHub OIDC provider (name in `JFROG_GITHUB_OIDC_PROVIDER`, default `github-oidc`) with issuer `https://token.actions.githubusercontent.com`, and per-repo identity mappings scoped to the agent repo and the main branch (the ref claim is still present in environment-scoped tokens) with deploy or write permission on the Docker repository only.
3. Docker repository: for dev the virtual repository is `byor-demo-docker` and pushes land in its local repository `byor-demo-docker-local`, which is where the GitHub mapping needs deploy permission. Images are therefore `trialndswdc.jfrog.io/byor-demo-docker/agent`.
4. Network reachability from Foundry's image pull path and from the build runners.

The foundation repo only manages the Foundry side. It never stores JFrog credentials.

## Image rules

- Built for `linux/amd64`, base python:3.12-slim, non-root user (uid 10001), listens on `$PORT` which defaults to 8088. The wrong architecture pulls fine and then never becomes active.
- CI pushes the tag `sha-<commit>`, resolves it to the JFrog `sha256` digest, and passes only the digest reference to Terraform. Tags are rejected by validation. The digest repository must be under `JFROG_REPO` and the image name `agent`.
- The live agent runs version 13 with digest `sha256:de6df2fa2ff77f37001adec600475a11d30e4273afa2e72566cfcbe3f7fc2b82`.

## The hosted agent in Foundry

- The logical agent is `private-registry-agent`, a Foundry data-plane resource of type `Microsoft.Foundry/agents@v1`, managed with `azapi_data_plane_resource` in `infra/hosted-agent`. Terraform imports the existing agent instead of recreating it (`import_existing_agent`).
- Changing the image creates a new version under the same agent; old versions stay in Foundry history. The endpoint routes 100 percent of traffic to `@latest`, so the newest active version becomes the default.
- The project endpoint has the form `https://<account>.services.ai.azure.com/api/projects/<project>`. Here the account is `kaiser-foundry-resource` and the project is `workshop-demo-project`.
- Allowed sizes (SKUs) are CPU and memory pairs: 0.5 CPU with 1Gi, 1 with 2Gi, and 2 with 4Gi. The list is hardcoded in `main.tf` and also read from the variable `SUPPORTED_AGENT_SKUS`, so the two can drift.
- A new version has a state: it must reach active; a failed state or a different image fails the smoke test.
- The platform-managed agent identity can reach project models by default, so no extra role assignment is needed for model mode, and the identity can change between deployments.

## The app (`app.py`)

- FastAPI service implementing Responses protocol 2.0.0: `POST /responses` (non-streaming and server-sent events streaming), alias `POST /v1/responses`, and `GET /healthz`, `/readiness` and `/liveness` for probes.
- The input may be a plain string or a message array. The reply is a Responses-shaped envelope with `output[].content[].output_text` plus the `output_text` convenience field.
- Echo mode (default): no model call, proves the registry plumbing. Model mode: set `AZURE_AI_MODEL_DEPLOYMENT_NAME` and the agent calls the Responses API on the project endpoint with its own Entra identity; no keys are in the image. Reasoning models reject legacy sampling parameters, so none are sent.
- Knowledge: every `knowledge/*.md` file is copied into the image and added to the model instructions, whole files in alphabetical order up to 60,000 characters; files that do not fit are listed under `knowledge_truncated` in `/healthz`.
- Scope gate: before any model call, code checks that the question mentions a known term. Terms come from backticked names in the knowledge files, key lines, a built-in list of general words, and any `scope:` comment a file declares. A question with no known term gets the fixed reply "Not in the knowledge base. Checked by code; the model was not called." A question about a capital city is answered from the Capital Cities section by lookup, without the model.
- `/healthz` reports the agent name, the mode (echo or model) and the loaded knowledge files.

## Microsoft Learn caveat

The Microsoft Learn BYOR article specifies the protocol name and version (responses 2.0.0) but not the full wire contract for a self-built container. The envelope here follows the standard Responses shape. If Foundry's invoke returns a protocol error, capture the request body it sends and adjust `create_response`; the image pull path is unaffected.
