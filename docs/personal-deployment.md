# Personal account, Signal and APNs deployment

These files prepare a separate service for the native app. They do not change the installed Mac
account, existing agents, routines, app data or `api.openbot.run`. No resource is created by the
default command. `deploy` is a separate action that changes the private Cloudflare resources.

Current choice (November 13, 2026): keep infrastructure local. Any later hosted setup must use
the existing server and email service. These templates remain preparation only.

## Resource plan

| Item | Personal target |
| --- | --- |
| Cloudflare account | `8ec1c186390d4346b8fcd6f9f3417b55` |
| Existing DNS zone | `maruotti.org`, `8bdb86e13ce258543afd70a8c2a53928` |
| Account Worker/domain | `openbot-personal-auth`, `openbot-api.maruotti.org` |
| Private SMTP relay | `openbot-personal-email-relay`, service binding only |
| D1 database | `openbot-personal-auth`, new private database ID required |
| R2 buckets | `openbot-personal-avatars`, `openbot-personal-skills`, `openbot-personal-sites` |
| Linux Signal/TURN | `openbot-signal.maruotti.org`, `openbot-turn.maruotti.org` |
| Apple team/topic | `X826DMJQDP`, `com.gerardomaruotti.openbot.native` |

The November 13 read-only account check found the domain active and these three DNS names unused.
It found no Workers, D1 databases, Tunnels or TURN keys. R2 requires account activation. Email
Sending access could not be confirmed. These are observations, not provisioned resources.

R2 is required by the current account Worker, including for minimal account/chat use:
`requireWorkerBindings()` in `apps/auth-api/src/server/types.ts` checks all three buckets before the
auth and readiness handlers run. These files retain that contract. They do not add dummy storage.

## Local preparation

From the repository root, show the plan without credentials, builds or network access:

```sh
python3 apps/auth-api/personal/deploy.py plan
```

Copy `apps/auth-api/personal/settings.example.json` and `secrets.example.json` to a private folder.
Use mode `0600` for the secrets file. Fill the settings only after the corresponding resources are
configured. The settings name the personal D1 ID, SMTP host/user/sender and Linux public IPv4.
No value in these files should refer to an upstream OpenBot account, service or secret.

Create a new P-256 ticket key pair with `kid: openbot-personal-1`. Store the private JWK and public
JWKS as JSON strings in the protected secrets file. Use fresh random secrets of at least 32 bytes
for the admin, report, webhook, session, TURN and metrics values. Do not reuse local development
defaults. Store the Apple `.p8` text and SMTP app password only in that file. The Cloudflare DNS
token must be limited to DNS edit for `maruotti.org`. Do not paste secret values into shell commands.

The SMTP account must accept TLS on port 465 and authorize `emailFrom`. The current email service
uses SMTP first; Cloudflare Email Service is an optional fallback, not a replacement for these
settings. No upstream mailbox, analytics, payment or third-party integration credential is used.

After the build lane is free, validate complete local inputs and write protected generated files:

```sh
python3 apps/auth-api/personal/deploy.py check --settings /private/settings.json --secrets-file /private/secrets.json
python3 apps/auth-api/personal/deploy.py dry-run --settings /private/settings.json
```

The dry run builds the existing Worker and checks packaging. It performs no D1 migration, secret
upload, deployment, DNS change or account switch. It does not establish remote readiness. Use this
wrapper alone for personal builds: it selects its standalone Wrangler config through the installed
Vite plugin's `CLOUDFLARE_VITE_WRANGLER_CONFIG_PATH` and checks the generated config before use.
Do not run it with another auth Worker build: Vite also updates its local deployment pointer.

Generated files stay in ignored `.openbot-build/personal-deployment/`, with private file modes.
The wrapper passes secrets to Wrangler through stdin. It removes inherited service credentials
and does not print child output, which can contain secrets. It uses the signed-in Wrangler profile;
the connected Cloudflare plugin and Wrangler have separate authentication.

## External setup and deployment

The operational dependencies are R2 activation and the three buckets, a private D1 database, an
authorized SMTP sender, and Linux Docker with static public IPv4, TLS and the TURN ports. Secrets
and both clients must use the same private account service. These dependencies are not configured
by local validation.

| Cost or service decision | Current status |
| --- | --- |
| Domain | Reuse the existing `maruotti.org`; no new domain purchase is needed. |
| R2 | Account checkout is required. Free usage is included; excess use is metered. Activation and charges are not approved by these files. |
| Linux, IPv4 and bandwidth | An existing suitable host can be used. None was verified. A new VPS subscription and its price need a separate decision. |
| SMTP | An existing authorized TLS465 account can be used. No new mailbox or email-service subscription has been selected. |
| Hosted agents and payments | Disabled. No agent-hosting subscription or payment integration is created. |

The existing upstream account can stay in use for normal chat while private setup is pending. It
cannot send pushes to this native app's separate Apple topic. A private Signal plus the current
coturn design can reuse an existing Linux host; changing it to a managed TURN provider would need
another adapter and validation, not just a credential substitution.

After private provisioning/deployment is authorized, sign Wrangler in to the personal account and
run the explicit remote action:

```sh
python3 apps/auth-api/personal/deploy.py deploy --settings /private/settings.json --secrets-file /private/secrets.json
```

It checks the account, applies only the private D1 migrations, deploys the private email relay,
uploads the private account secrets and deploys the reviewed built Worker. It does not create
billable resource subscriptions, buy servers, change Signal DNS or connect the installed Mac.
The account domain is a Worker Custom Domain; a `workers.dev` hostname is not needed.

On the selected Linux host, copy the reviewed source and generated protected `remote.env`. Keep
`remote.env` outside the source tree. The Docker context excludes `.openbot` and `.openbot-build`.
Set
`OPENBOT_SOURCE_COMMIT` to the reviewed source commit. Configure DNS-only A records for Signal and
TURN, and permit TCP 443, TCP/UDP 3478, TCP 5349 and UDP 16384–65535. Then use the separate project:

```sh
docker compose --env-file /private/remote.env -p openbot-personal-remote -f remote/personal/compose.yaml config --quiet
docker compose --env-file /private/remote.env -p openbot-personal-remote -f remote/personal/compose.yaml up -d --build
```

These commands are for that Linux host. They are not Mac readiness checks. The Compose file has
separate containers and certificate storage, no upstream token and no analytics reporter.

Check the account `/health/ready`, `/.well-known/jwks.json`, Signal `/health/ready`, email-code delivery,
remote chat with forced TURN, background APNs, and rejection after logout/session or membership
revocation. Health checks alone do not prove remote chat or push delivery. The notification route
retains its host credential, rate limit and per-send session/membership/account-session checks.

## Account switch comes last

First validate with a separate desktop profile and private account. The upstream and private
accounts are distinct, even if they use the same email address. Both clients must use the private
service to connect to a private host. There is no supported ticket delegation from `api.openbot.run`.

Do not point the existing signed-in profile at the new URL or run two processes against its database.
A later controlled cutover must preserve all agents, chats, routines and local data, sign out at the
correct service and bind the Mac to the private account. For the native build, set
`OPENBOT_NATIVE_ACCOUNT_URL` to the private API and enable `OPENBOT_NATIVE_PUSH_RELAY_TOPIC` only after
that relay is ready for the actual bundle ID. Physical-device and production APNs checks remain
separate. No TestFlight or App Store release is part of this setup.
