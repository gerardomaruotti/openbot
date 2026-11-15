#!/usr/bin/env python3
"""Prepare or deploy the separate personal control plane. The default only reports a plan."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
API = ROOT / "apps/auth-api"
TEMPLATES = API / "personal"
OUTPUT = ROOT / ".openbot-build/personal-deployment"
ACCOUNT = "8ec1c186390d4346b8fcd6f9f3417b55"
ZONE = "8bdb86e13ce258543afd70a8c2a53928"
API_ORIGIN = "https://openbot-api.maruotti.org"
SIGNAL_ORIGIN = "https://openbot-signal.maruotti.org"
TURN_DOMAIN = "openbot-turn.maruotti.org"
AUTH_SECRETS = ("EMAIL_SMTP_PASSWORD", "SKILLS_ADMIN_TOKEN", "SITE_REPORT_HASH_SECRET", "REMOTE_TICKET_PRIVATE_JWK", "REMOTE_TICKET_PUBLIC_JWKS", "REMOTE_AUTH_WEBHOOK_SECRET", "APNS_PRIVATE_KEY", "APNS_KEY_ID")
SERVER_SECRETS = ("REMOTE_SESSION_SECRET", "TURN_SHARED_SECRET", "REMOTE_METRICS_TOKEN", "CLOUDFLARE_DNS_API_TOKEN")


def load_json(path, private=False):
    path = Path(path).expanduser()
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("Configuration inputs must be regular files, not symbolic links.")
    if private and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077):
        raise ValueError("The secrets file must belong to this user and have mode 0600 or 0400.")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Configuration inputs must be JSON objects.")
    return value


def settings_problems(settings):
    expected = set(load_json(TEMPLATES / "settings.example.json"))
    problems = ["Unexpected settings keys."] if set(settings) != expected else []
    if settings.get("accountId") != ACCOUNT or settings.get("zoneId") != ZONE:
        problems.append("Use the reviewed personal Cloudflare account and maruotti.org zone.")
    database = settings.get("databaseId", "")
    if not isinstance(database, str) or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", database):
        problems.append("Set the existing personal D1 database ID.")
    upstream = (API / "wrangler.jsonc").read_text()
    if isinstance(database, str) and database and database in upstream:
        problems.append("The D1 database ID must not name an upstream database.")
    for flag in ("r2Enabled", "signalTurnConfigured"):
        if settings.get(flag) is not True:
            problems.append("Confirm " + flag + " only after the private resources are configured.")
    try:
        address = ipaddress.IPv4Address(settings.get("linuxPublicIPv4", ""))
        if not address.is_global:
            raise ValueError()
    except (ValueError, ipaddress.AddressValueError):
        problems.append("Set the public IPv4 address of the private Linux Signal/TURN host.")
    for key in ("smtpHost", "smtpUsername", "emailFrom", "acmeEmail"):
        value = settings.get(key)
        if not isinstance(value, str) or not value.strip() or value.startswith("SET_") or any(c in value for c in "\r\n\x00"):
            problems.append("Set " + key + ".")
    for key in ("emailFrom", "acmeEmail"):
        if not isinstance(settings.get(key), str) or not re.fullmatch(r"[^\s<>\"'@]+@[^\s<>\"'@]+\.[^\s<>\"'@]+", settings[key]):
            problems.append(key + " must be a plain email address.")
    host = settings.get("smtpHost", "")
    if isinstance(host, str) and not re.fullmatch(r"(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", host):
        problems.append("smtpHost must be a DNS host name without a port or credentials.")
    if any(isinstance(settings.get(k), str) and "openbot.run" in settings[k].lower() for k in ("smtpHost", "smtpUsername", "emailFrom", "acmeEmail")):
        problems.append("Do not use upstream OpenBot email identities.")
    return problems


def check_secrets(values):
    expected = set(AUTH_SECRETS + SERVER_SECRETS)
    if set(values) != expected:
        raise ValueError("Use only the secret names in personal/secrets.example.json.")
    if any(not isinstance(v, str) or not v.strip() or v.startswith(("SET_", "encrypted:")) for v in values.values()):
        raise ValueError("The protected secrets file is incomplete or still encrypted.")
    for key in ("SKILLS_ADMIN_TOKEN", "SITE_REPORT_HASH_SECRET", "REMOTE_AUTH_WEBHOOK_SECRET", "REMOTE_SESSION_SECRET", "TURN_SHARED_SECRET", "REMOTE_METRICS_TOKEN"):
        if len(values[key].encode()) < 32:
            raise ValueError(key + " must contain at least 32 bytes.")
    for key in SERVER_SECRETS + ("REMOTE_AUTH_WEBHOOK_SECRET",):
        if any(c in values[key] for c in "\r\n\x00'\\"):
            raise ValueError(key + " must use a single-line token without quote or backslash characters.")
    if not re.fullmatch(r"[A-Z0-9]{10}", values["APNS_KEY_ID"]):
        raise ValueError("APNS_KEY_ID must be a 10-character Apple key ID.")
    if not values["APNS_PRIVATE_KEY"].startswith("-----BEGIN PRIVATE KEY-----"):
        raise ValueError("APNS_PRIVATE_KEY must contain the Apple PKCS #8 key.")
    private = json.loads(values["REMOTE_TICKET_PRIVATE_JWK"])
    public = json.loads(values["REMOTE_TICKET_PUBLIC_JWKS"])
    keys = public.get("keys", []) if isinstance(public, dict) else []
    if not isinstance(private, dict) or len(keys) != 1 or not isinstance(keys[0], dict):
        raise ValueError("Use one private ticket JWK and its public JWKS.")
    public = keys[0]
    if not private.get("d") or "d" in public or any(private.get(k) != public.get(k) for k in ("kty", "crv", "x", "y", "kid")):
        raise ValueError("The private and public ticket keys must match; the JWKS must not contain private material.")
    if private.get("kty") != "EC" or private.get("crv") != "P-256" or private.get("kid") != "openbot-personal-1" or not private.get("x") or not private.get("y"):
        raise ValueError("Use a P-256 ticket key with kid openbot-personal-1.")


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink():
        raise ValueError("The personal output directory must not be a symbolic link.")
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        handle.write(value)
        temporary = Path(handle.name)
    temporary.chmod(0o600)
    temporary.replace(path)


def prepare(settings, secrets):
    worker = load_json(TEMPLATES / "wrangler.json")
    relay = load_json(TEMPLATES / "wrangler.email-relay.json")
    if worker.get("account_id") != ACCOUNT or relay.get("account_id") != ACCOUNT:
        raise ValueError("The template must target the reviewed personal Cloudflare account.")
    if worker.get("name") != "openbot-personal-auth" or relay.get("name") != "openbot-personal-email-relay":
        raise ValueError("The template must use separate personal Worker names.")
    if worker.get("routes") != [{"pattern": "openbot-api.maruotti.org", "custom_domain": True}]:
        raise ValueError("The template must use the reviewed personal API domain only.")
    if "openbot.run" in json.dumps([worker, relay]) or worker.get("env") or relay.get("routes"):
        raise ValueError("The personal templates must not refer to upstream services or other environments.")
    if worker.get("services") != [{"binding": "EMAIL_RELAY", "service": "openbot-personal-email-relay"}]:
        raise ValueError("The personal account must use its own email relay binding.")
    if worker.get("secrets", {}).get("required") != list(AUTH_SECRETS):
        raise ValueError("The template changed the reviewed account secret names.")
    if worker.get("workers_dev") is not False or worker.get("preview_urls") is not False or relay.get("workers_dev") is not False or relay.get("preview_urls") is not False:
        raise ValueError("The personal templates must not enable unreviewed public hostnames.")
    expected_buckets = [{"binding": name, "bucket_name": "openbot-personal-" + name.lower()} for name in ("AVATARS", "SKILLS", "SITES")]
    if worker.get("r2_buckets") != expected_buckets:
        raise ValueError("Use the three reviewed personal R2 buckets.")
    if len(worker.get("d1_databases", [])) != 1 or worker["d1_databases"][0].get("database_name") != "openbot-personal-auth" or worker["d1_databases"][0].get("binding") != "DB":
        raise ValueError("Use the reviewed personal D1 binding.")
    fixed = {
        "AUTH_EXPOSE_DEVELOPMENT_CODE": "false", "HOSTED_SERVERS_ENABLED": "false", "SITE_PUBLISH_ENABLED": "false",
        "APNS_TEAM_ID": "X826DMJQDP", "APNS_TOPIC": "com.gerardomaruotti.openbot.native",
        "REMOTE_SIGNAL_URL": "wss://openbot-signal.maruotti.org/v1/signal",
        "REMOTE_AUTH_WEBHOOK_URL": SIGNAL_ORIGIN + "/internal/auth-events",
        "REMOTE_SIGNAL_HOMES": "", "REMOTE_SIGNAL_HOME_LOCATIONS": "", "REMOTE_AUTH_WEBHOOK_URLS": "",
        "SIGNAL_ENTRY_ZONE_ID": "", "EMAIL_SMTP_PORT": "465", "EMAIL_LICENSE_FROM": "",
        "REMOTE_TICKET_KEY_ID": "openbot-personal-1", "HOSTED_SERVERS_ALLOWED_USER_IDS": "",
        "SITE_COOKIE_ISOLATION_READY": "false", "LICENSE_TRIAL_END": "",
    }
    if any(worker.get("vars", {}).get(k) != v for k, v in fixed.items()):
        raise ValueError("The template changed a required personal security or service setting.")
    if set(worker.get("vars", {})) != set(fixed) | {"EMAIL_SMTP_HOST", "EMAIL_SMTP_USERNAME", "EMAIL_FROM"}:
        raise ValueError("The template contains an unreviewed variable.")
    worker["main"] = str(API / "src/worker-entry.ts")
    worker["d1_databases"][0].update(database_id=settings["databaseId"], migrations_dir=str(API / "migrations"))
    worker["vars"].update(EMAIL_SMTP_HOST=settings["smtpHost"], EMAIL_SMTP_USERNAME=settings["smtpUsername"], EMAIL_FROM=settings["emailFrom"])
    relay["main"] = str(API / "src/email-relay-entry.ts")
    relay["placement"]["host"] = settings["smtpHost"] + ":465"
    for name, value in (("worker.json", worker), ("email-relay.json", relay)):
        write_private(OUTPUT / name, json.dumps(value, indent=2) + "\n")
    if secrets:
        server = {
            "ACME_EMAIL": settings["acmeEmail"], "SIGNAL_DOMAIN": "openbot-signal.maruotti.org", "TURN_DOMAIN": TURN_DOMAIN,
            "TURN_PUBLIC_IP": settings["linuxPublicIPv4"], "REMOTE_TICKET_JWKS_URL": API_ORIGIN + "/.well-known/jwks.json",
            "REMOTE_CONTROL_PLANE_URL": API_ORIGIN, "REMOTE_AUTH_WEBHOOK_SECRET": secrets["REMOTE_AUTH_WEBHOOK_SECRET"],
            **{name: secrets[name] for name in SERVER_SECRETS},
        }
        # Compose treats single-quoted dotenv values literally, including dollar signs.
        write_private(OUTPUT / "remote.env", "".join(k + "='" + v + "'\n" for k, v in server.items()))
    return worker


def child_environment():
    blocked = ("CLOUDFLARE_", "CLOUDFLARE_ENV", "WRANGLER_", "DOTENV_", "EMAIL_", "APNS_", "REMOTE_", "OPENPANEL_", "STRIPE_", "BOAT_", "VITE_")
    environment = {k: v for k, v in os.environ.items() if not k.startswith(blocked) and k not in ("NODE_OPTIONS", "BUN_OPTIONS")}
    environment.update(CLOUDFLARE_ACCOUNT_ID=ACCOUNT, CLOUDFLARE_VITE_WRANGLER_CONFIG_PATH=str(OUTPUT / "worker.json"), WRANGLER_SEND_METRICS="false")
    return environment


def run(command, label, environment, input_text=None):
    # Capture child output: a failed CLI must not echo a secret from stdin into this script's output.
    result = subprocess.run(command, cwd=API, env=environment, input=input_text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(label + " failed with exit code " + str(result.returncode) + ". Child output was not printed because it can contain secrets.")
    print(label + ": passed")
    return result.stdout


def validate_built_config(path, reviewed):
    built = load_json(path)
    for key in ("name", "account_id", "routes", "vars", "services", "r2_buckets", "ratelimits", "triggers"):
        if built.get(key) != reviewed.get(key):
            raise ValueError("The generated Worker changed reviewed configuration: " + key + ".")
    databases = built.get("d1_databases", [])
    expected = reviewed["d1_databases"][0]
    if len(databases) != 1 or any(databases[0].get(k) != expected[k] for k in ("binding", "database_id", "database_name")):
        raise ValueError("The generated Worker changed the private D1 binding.")
    if built.get("workers_dev") is not False or built.get("preview_urls") is not False:
        raise ValueError("The generated Worker enabled an unreviewed public hostname.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "check", "dry-run", "deploy"), nargs="?", default="plan")
    parser.add_argument("--settings", type=Path, default=TEMPLATES / "settings.example.json")
    parser.add_argument("--secrets-file", type=Path)
    args = parser.parse_args()
    settings = load_json(args.settings)
    problems = settings_problems(settings)
    if args.action == "plan":
        print(json.dumps({"accountId": ACCOUNT, "zoneId": ZONE, "accountOrigin": API_ORIGIN, "signalOrigin": SIGNAL_ORIGIN, "turnDomain": TURN_DOMAIN, "blocked": problems, "remoteChanges": False}, indent=2))
        return
    if problems:
        raise ValueError("Private deployment is blocked: " + " ".join(problems))
    secrets = None
    if args.secrets_file:
        secrets = load_json(args.secrets_file, private=True)
        check_secrets(secrets)
    if args.action in ("check", "deploy") and secrets is None:
        raise ValueError("Provide a protected --secrets-file; secret values are never command arguments.")
    OUTPUT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (OUTPUT / "operation.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        reviewed = prepare(settings, secrets)
        if args.action == "check":
            print("Private configuration and protected secret inputs: passed. Remote resources have not been checked or changed.")
            return
        bun = os.environ.get("BUN_BINARY") or shutil.which("bun") or str(ROOT / ".openbot-build/native-ios/tooling/node_modules/.bin/bun")
        wrangler = ROOT / "node_modules/.bin/wrangler"
        environment = child_environment()
        output = OUTPUT / "dist"
        started = time.time()
        run([bun, "run", "build", "--outDir", str(output)], "Private account build", environment)
        redirect = API / ".wrangler/deploy/config.json"
        if redirect.stat().st_mtime < started:
            raise ValueError("The private build did not write a current deployment pointer.")
        pointer = load_json(redirect)
        built = (redirect.parent / pointer["configPath"]).resolve()
        if not built.is_relative_to(output.resolve()):
            raise ValueError("The build output is outside the private deployment directory.")
        validate_built_config(built, reviewed)
        if args.action == "dry-run":
            run([str(wrangler), "deploy", "--config", str(built), "--dry-run", "--outdir", str(OUTPUT / "dry-run")], "Private account packaging dry run", environment)
            run([str(wrangler), "deploy", "--config", str(OUTPUT / "email-relay.json"), "--dry-run", "--outdir", str(OUTPUT / "relay-dry-run")], "Private email relay packaging dry run", environment)
            return
        # Only the explicit deploy action below can change remote resources.
        who = json.loads(run([str(wrangler), "whoami", "--json"], "Cloudflare identity read", environment))
        if not any(x.get("id") == ACCOUNT for x in who.get("accounts", [])):
            raise ValueError("Wrangler is not signed in to the reviewed personal Cloudflare account.")
        run([str(wrangler), "d1", "migrations", "apply", "DB", "--remote", "--yes", "--config", str(OUTPUT / "worker.json")], "Private D1 migrations", environment)
        run([str(wrangler), "deploy", "--config", str(OUTPUT / "email-relay.json")], "Private email relay deployment", environment)
        assert secrets is not None
        run([str(wrangler), "secret", "bulk", "--config", str(OUTPUT / "worker.json")], "Private account secrets", environment, json.dumps({name: secrets[name] for name in AUTH_SECRETS}))
        run([str(wrangler), "deploy", "--config", str(built)], "Private account deployment", environment)
        print("Private account deployed. Signal/TURN installation and end-to-end acceptance are separate steps. The existing Mac account was not changed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, BlockingIOError) as error:
        # Do not include JSON parser input snippets or child-process output in an error.
        message = str(error) if not isinstance(error, json.JSONDecodeError) else "An input file is not valid JSON."
        print(message, file=sys.stderr)
        sys.exit(1)
