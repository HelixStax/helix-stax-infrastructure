# Cloudflare Setup Reference

Operational guide for managing Cloudflare configuration across Helix Stax domains.

For the full DNS record inventory, see [dns-records.md](../dns-records.md).

---

## Account Overview

| Detail | Value |
|--------|-------|
| **Account email** | `contact@wakeemwilliams.com` |
| **Domains** | `helixstax.net` (private/ops), `helixstax.com` (public/clients) |
| **helixstax.net zone ID** | `5a66e66839972aa4bb7f2f62c18cdf84` |

Both domains live under the same Cloudflare account.

### Domain Purpose

| Domain | Audience | Cloud Mode | TLS Strategy |
|--------|----------|------------|--------------|
| `helixstax.net` | Internal ops | Grey cloud (DNS only) | Let's Encrypt via DNS-01 challenge |
| `helixstax.com` | Public / clients | Orange cloud (proxied) | Cloudflare origin certificates |

---

## Grey Cloud vs Orange Cloud

| | Grey Cloud (DNS Only) | Orange Cloud (Proxied) |
|---|---|---|
| **Traffic flow** | Client connects directly to origin IP | Client connects to Cloudflare edge, edge connects to origin |
| **Origin IP** | Exposed | Hidden |
| **TLS** | You provide the cert (Let's Encrypt) | Cloudflare terminates TLS at edge; origin cert secures the hop |
| **DDoS / WAF / Cache** | Not active | Active |
| **Use when** | Internal services, VPN endpoints, anything that needs direct TCP/UDP | Public websites, anything benefiting from CDN or DDoS protection |

**Rule of thumb**: If users reach the service over Netbird or you need non-HTTP protocols, use grey cloud. If it is internet-facing for the public, use orange cloud.

---

## API Token Setup

### Creating a Scoped Token

1. Go to [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Click **Create Token**
3. Use the **Edit zone DNS** template, or create custom:
   - **Permissions**: `Zone > DNS > Edit`
   - **Zone Resources**: Include > Specific zone > `helixstax.net`
4. Click **Continue to summary** > **Create Token**
5. Copy the token immediately (it is shown only once)

### Storing the Token on VPS

The token lives at `/opt/helix-stax/nginx/cloudflare.ini` on VPS `5.78.145.30`. Certbot reads this file for DNS-01 challenges.

**Scoped token format** (preferred):

```ini
dns_cloudflare_api_token = YOUR_SCOPED_TOKEN
```

**Global API key format** (legacy, avoid if possible):

```ini
dns_cloudflare_email = contact@wakeemwilliams.com
dns_cloudflare_api_key = YOUR_GLOBAL_API_KEY
```

### Security

```bash
chmod 600 /opt/helix-stax/nginx/cloudflare.ini
chown root:root /opt/helix-stax/nginx/cloudflare.ini
```

- Never commit this file to git.
- Rotate the token periodically. When rotating: create new token first, update `cloudflare.ini`, test with `certbot renew --dry-run`, then revoke the old token.

---

## Zone Settings (helixstax.net)

All `helixstax.net` records use grey cloud, so Cloudflare does not proxy traffic. The following features are irrelevant and should be disabled to avoid confusion:

| Setting | Value | Why |
|---------|-------|-----|
| `automatic_https_rewrites` | Off | CF is not in the request path |
| `browser_check` | Off | CF is not in the request path |
| `email_obfuscation` | Off | CF is not rewriting HTML |
| `server_side_exclude` | Off | CF is not rewriting HTML |
| `replace_insecure_js` | Off | CF is not in the request path |
| `cache_level` | Basic | No content to cache when grey-clouded |

**For helixstax.com** (future, orange cloud): re-evaluate all of these. Automatic HTTPS rewrites, browser check, and caching should likely be enabled.

---

## CLI Commands

All commands use the Cloudflare API v4. Replace these placeholders:

| Placeholder | Meaning |
|-------------|---------|
| `$CF_TOKEN` | Your scoped API token |
| `$ZONE_ID` | Zone ID (`5a66e66839972aa4bb7f2f62c18cdf84` for helixstax.net) |
| `$RECORD_ID` | ID of a specific DNS record (from list command) |

### List DNS Records

```bash
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" | jq '.result[] | {id, name, type, content, proxied}'
```

### Create an A Record

```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "A",
    "name": "SUBDOMAIN.helixstax.net",
    "content": "TARGET_IP",
    "ttl": 1,
    "proxied": false
  }' | jq '.result | {id, name, content, proxied}'
```

- `"ttl": 1` means automatic (Cloudflare picks).
- `"proxied": false` means grey cloud.

### Delete a DNS Record

```bash
curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" | jq '.success'
```

### Check Zone Settings

```bash
curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" | jq '.result[] | {id, value}'
```

### Update a Zone Setting

```bash
curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/SETTING_NAME" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"value": "off"}' | jq '{id: .result.id, value: .result.value}'
```

Replace `SETTING_NAME` with one of: `automatic_https_rewrites`, `browser_check`, `email_obfuscation`, `server_side_exclude`, `replace_insecure_js`.

---

## Troubleshooting

### DNS Not Resolving

1. **Check cloud mode**: Did someone flip a record from grey to orange (or vice versa)?
   ```bash
   dig +short SUBDOMAIN.helixstax.net
   ```
   If the response is a Cloudflare IP (e.g., `104.x.x.x`) instead of the origin, the record was proxied accidentally.

2. **Check TTL**: Cloudflare's automatic TTL (grey cloud) is ~300s. If you just changed a record, wait 5 minutes.

3. **Check propagation**: Use an external tool to confirm:
   ```bash
   dig @1.1.1.1 SUBDOMAIN.helixstax.net
   dig @8.8.8.8 SUBDOMAIN.helixstax.net
   ```

4. **Check the record exists**: List records via API (see CLI section above) and confirm the subdomain is present.

### API Returns "9103 Unknown X-Auth-Key"

You are mixing auth methods. Either use:

- **Bearer token** (scoped): `Authorization: Bearer $CF_TOKEN`
- **Global key** (legacy): `X-Auth-Email` + `X-Auth-Key` headers

Do not combine them. If using a scoped token, remove any `X-Auth-Email` / `X-Auth-Key` headers.

### Certificate Errors on helixstax.net

Grey cloud means Cloudflare is **not** terminating TLS. The browser connects directly to the origin.

- You need a real certificate on the origin (Let's Encrypt, not a Cloudflare origin cert).
- Cloudflare origin certs are only trusted by Cloudflare's edge — they will cause browser errors when grey-clouded.
- Verify certbot is working:
  ```bash
  certbot certificates
  ```
- Force a renewal test:
  ```bash
  certbot renew --dry-run
  ```
- If certbot fails with DNS errors, check that `/opt/helix-stax/nginx/cloudflare.ini` has the correct token and the token has `Zone:DNS:Edit` permission for the `helixstax.net` zone.

### Certificate Errors on helixstax.com (Future)

Orange cloud means Cloudflare terminates TLS at the edge. The origin needs a **Cloudflare origin certificate** (not Let's Encrypt).

- Generate one in the Cloudflare dashboard: SSL/TLS > Origin Server > Create Certificate.
- Install it on the origin (K3s worker node).
- Set SSL mode to **Full (strict)** in Cloudflare dashboard.
