-- Helix Stax: Initialize all service databases
-- Runs automatically on first container start (executed as postgres superuser)
-- Services get dedicated credentials when deployed; this creates the DB slots now.

-- Authentik (identity provider)
CREATE DATABASE authentik;

-- Harbor (container registry)
CREATE DATABASE harbor;
CREATE DATABASE harbor_notary_server;
CREATE DATABASE harbor_notary_signer;

-- NetBird (mesh VPN)
CREATE DATABASE netbird;

-- Devtron (CI/CD platform — future)
CREATE DATABASE devtron;

-- n8n (workflow automation — future)
CREATE DATABASE n8n;

-- Langfuse (LLM observability — future)
CREATE DATABASE langfuse;
