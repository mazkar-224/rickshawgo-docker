# Proof of work: Assignment 4 (Deploy a dockerized Node.js application)

All outputs below are copied from real runs on 2026-11-22 (PKT, UTC+5). The raw logs are in [`docs/proof/`](proof/).

| Requirement | Done | Proof |
|---|---|---|
| 1. Dockerize the Node.js app from the previous assignments | ✅ | [§1](#1-the-image) |
| 2. Deploy it to the VM | ✅ | [§2](#2-deployed-on-the-vm), [§5](#5-zero-downtime-rolling-update), [§6](#6-a-broken-release-rolls-back-by-itself), [§7](#7-survives-a-reboot) |
| 3. Update the Nginx configs | ✅ | [§3](#3-nginx) |
| 4. Route the domain and install an SSL certificate | ✅ | [§4](#4-domain-and-ssl) |
| Extra: CI that tests, scans and publishes the image | ✅ | [§8](#8-ci-on-github-actions) |

---

## 1. The image

The app is the RickshawGo API (Node.js 24 / Express 5) that ran under systemd in assignment 3. Changes needed for a container:
- it listened on a hard-coded `127.0.0.1`. Inside a container that's the container's *own* loopback, so nothing outside could reach it. Now
  `HOST` is configurable; the image sets `HOST=0.0.0.0`, and the outside exposure is controlled by Docker's port mapping (127.0.0.1 only, see §2).
- Node as PID 1 ignored `SIGTERM`, so `docker stop` took 10 s and then a kill. Now it closes gracefully:
  ```
  docker stop took 0s
  SIGTERM received: closing the server
  ```
- `/api/health` now reports `instance` (the container hostname), because inside a container every pid is 1.

Built locally and scanned:
```
$ docker run --rm ... rickshawgo-api:local id
uid=1000(node) gid=1000(node) groups=1000(node)
$ docker run --rm --entrypoint sh rickshawgo-api:local -c 'which npm yarn npx'
no package managers in the image
$ hadolint Dockerfile
(clean)
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed rickshawgo-api:local
HIGH/CRITICAL fixable vulnerabilities: 0          (OS: alpine 3.24.4)
```
Tests (Node's built-in runner, against the real server):
```
✔ GET /api/health reports ok and the version
✔ GET /api/rickshaws/free lists only free rickshaws
✔ GET /api/rickshaws/count matches the list
✔ unknown paths answer 404 with JSON, and Express is not advertised
✔ the server refuses to start without MAPS_KEY
ℹ tests 5   ℹ pass 5   ℹ fail 0
```

## 2. Deployed on the VM

Docker Engine 29.10 + Compose v5.8 from Docker's official apt repository. The repository is cloned to `/opt/rickshawgo`, and the secret is in
`/etc/rickshawgo/app.env` (`-rw------- root root`).
```
$ sudo /opt/rickshawgo/scripts/deploy.sh sha-044fb9f
==> Live tag now: none   ->   deploying: sha-044fb9f
==> Pulling ghcr.io/mazkar-224/rickshawgo-docker:sha-044fb9f
==> Updating api-1
 Container rickshawgo-api-1-1 Healthy
==> api-1 is healthy on sha-044fb9f; waiting 3s so Nginx uses it again
==> Updating api-2
 Container rickshawgo-api-2-1 Healthy
==> Deployed sha-044fb9f

$ sudo docker ps
NAMES                IMAGE                                              STATUS                    PORTS
rickshawgo-api-2-1   ghcr.io/mazkar-224/rickshawgo-docker:sha-044fb9f   Up 8 seconds (healthy)    127.0.0.1:3102->3000/tcp
rickshawgo-api-1-1   ghcr.io/mazkar-224/rickshawgo-docker:sha-044fb9f   Up 17 seconds (healthy)   127.0.0.1:3101->3000/tcp
```
The VM pulled the image **anonymously** (public package): no registry credentials on the server.

Container hardening, as actually running (`docker inspect`):
```
User=1000:1000  ReadonlyRootfs=true  CapDrop=[ALL]  SecurityOpt=[no-new-privileges:true]  Init=true
Restart=unless-stopped  Memory=268435456 (256 MB)  NanoCpus=500000000 (0.5 CPU)  Log=map[max-file:3 max-size:10m]

$ docker exec rickshawgo-api-1-1 sh -c 'id; touch /app/x; touch /x; ps'
uid=1000(node) gid=1000(node) groups=1000(node)
touch: /app/x: Read-only file system
touch: /x: Read-only file system
    1 node     /sbin/docker-init -- docker-entrypoint.sh node server.js
    7 node     {MainThread} node server.js

$ docker image inspect ... --format '{{json .Config.Env}}'        # no MAPS_KEY baked into the image
["PATH=...","NODE_VERSION=24.22.3","YARN_VERSION=1.22.22","NODE_ENV=production","HOST=0.0.0.0","PORT=3000"]

$ sudo ss -tlnp | grep -E ':310[12] '                              # containers reachable only from the VM itself
127.0.0.1:3101
127.0.0.1:3102
```

## 3. Nginx

New site `rickshawgo` ([nginx/rickshawgo.conf](../nginx/rickshawgo.conf)) and a TLS catch-all ([nginx/00-default-tls.conf](../nginx/00-default-tls.conf)):
```
$ sudo nginx -t
nginx: configuration file /etc/nginx/nginx.conf test is successful
```
- `upstream rickshawgo_containers` = 127.0.0.1:3101 + 127.0.0.1:3102, with a shared `zone`, `max_fails=1 fail_timeout=2s`, `keepalive 16`
- `proxy_next_upstream error timeout http_502 http_503`: if one container is restarting, the request goes to the other one
- port 80: `301` to HTTPS only. Port 443: TLS 1.2/1.3, HSTS and security headers, `server_tokens off`

Load balancing: requests alternate between the two containers:
```
{"status":"ok","version":"2.2","instance":"api-1","port":3000,"pid":7}
{"status":"ok","version":"2.2","instance":"api-2","port":3000,"pid":7}
{"status":"ok","version":"2.2","instance":"api-1","port":3000,"pid":7}
{"status":"ok","version":"2.2","instance":"api-2","port":3000,"pid":7}
```

## 4. Domain and SSL

Domain: **`rickshawgo.azkar.test`**. Certificate: issued by my lab CA ([scripts/make-cert.sh](../scripts/make-cert.sh)), ECDSA P-256, SAN = the domain, valid 397 days.
The CA's private key never left my laptop; only its public certificate is in [ssl/](../ssl/).
```
subject= /CN=rickshawgo.azkar.test
issuer= /O=Azkar DevOps Lab/CN=Azkar Lab Root CA
notAfter=Dec 24 15:36:42 2027 GMT
X509v3 Subject Alternative Name: DNS:rickshawgo.azkar.test
```
Checks on the VM (no `-k` anywhere: curl verifies the certificate against the lab CA):
```
### HTTP -> HTTPS redirect:
301 -> https://rickshawgo.azkar.test/api/rickshaws/count
### security headers:
HTTP/2 200
server: nginx                                   (version hidden)
strict-transport-security: max-age=31536000
x-content-type-options: nosniff
x-frame-options: DENY
referrer-policy: no-referrer
### TLS handshake (openssl s_client):
subject=CN = rickshawgo.azkar.test
issuer=O = Azkar DevOps Lab, CN = Azkar Lab Root CA
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Verify return code: 0 (ok)
### an unknown host name is refused:      unrecognized name
### old TLS 1.1 is refused:                no protocols available
```
From my laptop through the "router" (`lab/edge`, ports 80/443 → VM):
```
$ curl --cacert ssl/azkar-lab-root-ca.crt https://rickshawgo.azkar.test/api/rickshaws/count
{"total":4,"free":3}
```
**A bug I found and fixed on the way:** the first certificate failed with
`SSL certificate problem: Certificate public key has explicit ECC parameters`. macOS's LibreSSL (`openssl req -newkey ec`) writes EC keys
with explicit curve parameters, which OpenSSL 3 clients reject. `make-cert.sh` now generates keys with `-param_enc named_curve` (works with both).

## 5. Zero-downtime rolling update

From `sha-044fb9f` to `sha-a74aace`, while my laptop sent HTTPS requests every 0.1 s through the edge and Nginx:
```
==> Live tag now: sha-044fb9f   ->   deploying: sha-a74aace
==> Updating api-1
 Container rickshawgo-api-1-1 Recreate ... Healthy
==> api-1 is healthy on sha-a74aace; waiting 3s so Nginx uses it again
==> Updating api-2
 Container rickshawgo-api-2-1 Recreate ... Healthy
==> api-2 is healthy on sha-a74aace; waiting 3s so Nginx uses it again
==> Through Nginx + TLS: {"status":"ok","version":"2.2","instance":"api-1","port":3000,"pid":7}
==> Deployed sha-a74aace

curl loop from the laptop during the deploy (250 HTTPS requests):
    250 200
```

## 6. A broken release rolls back by itself

A deliberately broken image (the app starts, but its health check always fails), deployed with the normal script:
```
==> Live tag now: sha-a74aace   ->   deploying: broken-test
==> Updating api-1
container rickshawgo-api-1-1 is unhealthy
ERROR: api-1 did not become healthy on broken-test
ERROR: rolling api-1 back to sha-a74aace
 Container rickshawgo-api-1-1 Healthy
ERROR: deployment of broken-test stopped; the other container is still on sha-a74aace
deploy exit code: 1

api-1 ghcr.io/mazkar-224/rickshawgo-docker:sha-a74aace Up 5 seconds (healthy)
api-2 ghcr.io/mazkar-224/rickshawgo-docker:sha-a74aace Up About a minute (healthy)
recorded live tag: sha-a74aace

curl loop from the laptop during the failed deploy and the rollback (350 HTTPS requests):
    350 200
```
A tag that doesn't exist is refused before anything changes:
```
ERROR: could not pull ghcr.io/mazkar-224/rickshawgo-docker:sha-0000000: nothing was changed
```

## 7. Survives a reboot

After restarting the whole VM, without touching anything:
```
docker: active   containerd: active   nginx: active
rickshawgo-api-1-1   ghcr.io/mazkar-224/rickshawgo-docker:sha-a74aace   Up 13 seconds (healthy)   127.0.0.1:3101->3000/tcp
rickshawgo-api-2-1   ghcr.io/mazkar-224/rickshawgo-docker:sha-a74aace   Up 13 seconds (healthy)   127.0.0.1:3102->3000/tcp
from the laptop: {"total":4,"free":3}
```
(`restart: unless-stopped` + Docker enabled at boot. The lab-only Docker disk is mounted by systemd before Docker starts.)

## 8. CI on GitHub Actions

[Actions → CI](https://github.com/mazkar-224/rickshawgo-docker/actions/workflows/ci.yml): every push and pull request runs four jobs:
```
✓ Unit tests (Node 24)                      ℹ tests 5  ℹ pass 5  ℹ fail 0
✓ Lint Dockerfile, Compose and scripts      hadolint · shellcheck · docker compose config
✓ Build, smoke-test and scan the image      container health: healthy
                                            {"status":"ok","version":"2.2",...}{"total":4,"free":3}runs as uid 1000, not root
                                            docker stop took 0s / SIGTERM received: closing the server
                                            Trivy: no fixable HIGH/CRITICAL vulnerabilities
✓ Publish to ghcr.io                        ghcr.io/mazkar-224/rickshawgo-docker:sha-xxxxxxx and :latest (+ SBOM, provenance)
```
**CI caught a real bug:** the first run failed. `node --test test/` worked on my laptop (Node 26), but Node 24, the version in the image,
reads a bare `test/` as a single file (`Cannot find module '.../app/test'`). Fixed with an explicit glob (`node --test "test/**/*.test.js"`).
That's exactly why CI runs the production Node version and not whatever is on a laptop.

Dependabot watches the base image, npm packages and actions, and opens a pull request for each update (which then goes through the same CI).
