# Devtron OIDC SSO Integration — Architecture

**Status**: Implemented
**Date**: 2026-03-25
**Identity Provider**: Zitadel (zitadel.helixstax.net)
**Target**: Devtron v2.1.1 (chart 0.23.2)

---

## Overview

Devtron uses Dex (an OIDC identity broker) for SSO. In Devtron v2.x, the operator
manages its own Dex deployment (`devtron-dex-server` pod in `devtroncd` namespace).
This is separate from ArgoCD's Dex — Devtron has its own dex instance that reads
its configuration from `devtron-secret.DEX_CONFIG` (base64-encoded YAML).

Zitadel acts as the upstream OIDC provider. Dex federates from Zitadel using the
`oidc` connector type.

```
Browser
   |
   v
devtron.helixstax.net (Cloudflare tunnel -> Traefik -> devtron-service:80)
   |
   | (login redirect)
   v
devtron-dex-server:5556 (Dex OIDC broker, internal)
   |
   | (OIDC authorization_code flow)
   v
zitadel.helixstax.net (Zitadel IdP)
   |
   | (user authenticates with Zitadel credentials)
   v
callback -> devtron-dex-server -> issues Devtron JWT
```

---

## Devtron SSO Config Location

| Component        | Key               | Content |
|------------------|-------------------|---------|
| `devtron-secret` | `DEX_CONFIG`      | Base64-encoded Dex YAML config |
| `devtron-cm`     | `DEX_HOST`        | `http://devtron-service.devtroncd/dex` |
| `devtron-secret` | `DEVTRON_SECRET_KEY` | Devtron JWT signing key (set by operator) |

The `devtron-oidc-zitadel` Secret (this repo) holds the Zitadel client credentials.
The `devtron-setup-oidc.sh` script reads from it and patches `devtron-secret.DEX_CONFIG`.

---

## Zitadel Application

- **Type**: Web (OIDC, authorization_code + PKCE)
- **Project**: helix-platform (ID: 365717240378556639)
- **Redirect URI**: `https://devtron.helixstax.net/auth/callback`
- **Post-logout URI**: `https://devtron.helixstax.net`
- **Auth method**: POST (client_secret_post)
- **Claims**: openid, email, profile, groups
- **Role assertions**: enabled (for role-based access in Devtron)

---

## Dex Connector Config (stored in devtron-secret.DEX_CONFIG)

```yaml
issuer: http://devtron-service.devtroncd/dex

storage:
  type: kubernetes
  config:
    inCluster: true

web:
  http: 0.0.0.0:5556

oauth2:
  skipApprovalScreen: true
  responseTypes:
    - code

connectors:
  - type: oidc
    id: zitadel
    name: "Zitadel"
    config:
      issuer: https://zitadel.helixstax.net
      clientID: $DEVTRON_ZITADEL_CLIENT_ID
      clientSecret: $DEVTRON_ZITADEL_CLIENT_SECRET
      redirectURI: https://devtron.helixstax.net/auth/callback
      scopes:
        - openid
        - email
        - profile
        - groups
      userNameKey: preferred_username
      userIDKey: sub
      insecureSkipEmailVerified: false
      promptType: consent

staticClients:
  - id: argo-cd-cli
    name: Argo CD CLI
    public: true
    redirectURIs:
      - http://localhost:8085/auth/callback
  - id: devtron-cli
    name: Devtron CLI
    public: true
    redirectURIs:
      - http://localhost:8085/auth/callback
```

The `$DEVTRON_ZITADEL_CLIENT_ID` and `$DEVTRON_ZITADEL_CLIENT_SECRET` are substituted
by the setup script from the `devtron-oidc-zitadel` K8s secret before base64-encoding.

---

## Access Control

Devtron uses its own RBAC separate from Zitadel roles. Users authenticate via Zitadel
but authorization is managed within Devtron's permission model:

- **Super Admin**: Initial setup via Devtron UI — grant to Wakeem's Zitadel email
- **Manager**: Team-level, can deploy to production
- **Trigger**: Team-level, can trigger pipelines
- **View**: Read-only

After SSO is enabled, the local admin account (`admin`) remains available as a
fallback. Do NOT disable it until SSO is verified working.

---

## Troubleshooting

### Dex pod not starting
```bash
kubectl logs -n devtroncd -l app=dex
```
Check for YAML parse errors in DEX_CONFIG.

### Login redirects to Zitadel but fails with "invalid_client"
- Verify `clientID` and `clientSecret` match what Zitadel issued
- Verify redirect URI in Zitadel app matches exactly: `https://devtron.helixstax.net/auth/callback`

### Login returns to Devtron but user has no permissions
- User exists in Devtron (SSO login creates the user) but has no roles assigned
- Go to Devtron > Global Config > Auth > Users — assign roles

### Groups claim not populated
- Verify Zitadel "addGroupsClaim" Action is created and assigned to the helix-platform project
- This is the same Action used for Grafana SSO

---

## References

- [Devtron SSO docs](https://docs.devtron.ai/usage/global-configurations/sso-login-service)
- [Dex OIDC connector](https://dexidp.io/docs/connectors/oidc/)
- [grafana-oidc-setup.sh](../../scripts/grafana-oidc-setup.sh) — reference for Zitadel API pattern
