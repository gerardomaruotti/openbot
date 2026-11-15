// Runs the real Signal entry point with throwaway loopback TLS and account fixtures. After the
// natural five-minute renewal interval, a mismatched key or an expired matching certificate must
// leave the authenticated WSS peer and fresh HTTPS connections usable. No production timer,
// certificate, account, service or environment file is changed.
import { type ChildProcess, spawn } from "node:child_process";
import {
  createHash,
  createPrivateKey,
  generateKeyPairSync,
  randomBytes,
  randomUUID,
  X509Certificate,
} from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, get as httpGet, type Server } from "node:http";
import { Agent as HttpsAgent, get as httpsGet } from "node:https";
import { createServer as createNetServer } from "node:net";
import { tmpdir } from "node:os";
import { basename, isAbsolute, relative, resolve, sep } from "node:path";
import { decodeSignalServerMessage } from "@openbot/contracts/signal-protocol/decode";
import { REMOTE_TICKET_AUDIENCE, REMOTE_TICKET_PROTOCOL_VERSION } from "@openbot/contracts/signal-protocol/ticket";
import { exportJWK, SignJWT } from "jose";
import WebSocket from "ws";

const ROOT = resolve(import.meta.dirname, "..");
const BUILD = resolve(ROOT, ".openbot-build");
const RENEWAL_DEADLINE_MS = 330_000;
const PROBE_TIMEOUT_MS = 1_500;
const STARTUP_DEADLINE_MS = 30_000;
const runId = randomUUID();
const args = process.argv.slice(2);
const usage =
  "Usage: bun scripts/signal-tls-renewal-e2e.ts [--output .openbot-build/<fresh-directory>] [--scenario mismatched-key|expired-certificate]";
let requestedOutput: string | undefined;
let scenario: "mismatched-key" | "expired-certificate" = "mismatched-key";
let scenarioSet = false;
for (let index = 0; index < args.length; index += 2) {
  const option = args[index];
  const value = args[index + 1];
  if (!value) throw new Error(usage);
  if (option === "--output" && requestedOutput === undefined) requestedOutput = value;
  else if (option === "--scenario" && !scenarioSet && (value === "mismatched-key" || value === "expired-certificate")) {
    scenario = value;
    scenarioSet = true;
  } else throw new Error(usage);
}
const output = resolve(ROOT, requestedOutput ?? `.openbot-build/signal-tls-renewal-e2e/${runId}`);
const outputRelative = relative(BUILD, output);
if (!outputRelative || outputRelative === ".." || outputRelative.startsWith(`..${sep}`) || isAbsolute(outputRelative)) {
  throw new Error("The output directory must be inside .openbot-build.");
}
await mkdir(resolve(output, ".."), { recursive: true });
// Reject an existing run directory instead of replacing someone else's evidence.
await mkdir(output);

type FailureCode =
  | "interrupted"
  | "fixture_failed"
  | "signal_exited"
  | "signal_startup_failed"
  | "peer_authentication_failed"
  | "renewal_not_observed"
  | "known_good_listener_lost"
  | "existing_peer_lost"
  | "readiness_not_truthful";

class FixtureFailure extends Error {
  constructor(readonly code: FailureCode) {
    super(code);
  }
}

interface Probe {
  ok: boolean;
  status: number | null;
  errorCode: string | null;
  durationMs: number;
}

interface RenewalObservation {
  outcome: "accepted" | "rejected";
  observedAt: number;
}

interface StagedCertificateObservation {
  validFrom: string;
  validTo: string;
  expiredBeforeReplacement: boolean;
  matchesPrivateKey: boolean;
  signedByTrustedRoot: boolean;
  loopbackSANValid: boolean;
  initialValidBeyondRenewalDeadline: boolean;
}

const abort = new AbortController();
const onInterrupt = () => abort.abort();
process.on("SIGINT", onInterrupt);
process.on("SIGTERM", onInterrupt);

const startedAt = Date.now();
let fixture: string | null = null;
let child: ChildProcess | null = null;
let controlPlane: Server | null = null;
let peer: WebSocket | null = null;
let peerAgent: HttpsAgent | null = null;
let pingTimer: ReturnType<typeof setInterval> | null = null;
const observed: { renewal: RenewalObservation | null } = { renewal: null };
let closedCode: number | null = null;
let closedCodeAfterRenewal: number | null = null;
let ready = false;
let fixtureKeyReplacedAt: number | null = null;
let stagedCertificate: StagedCertificateObservation | null = null;
let failure: FailureCode | null = null;
let beforeTls: Probe | null = null;
let beforeHealth: Probe | null = null;
let afterHealth: Probe | null = null;
const afterTls: Probe[] = [];
let afterPeerPong = false;
let childAliveAfterRenewal = false;
let childStopped = true;
let fixtureRemoved = true;
const sourceHashes: Record<string, string> = {};

function requireRunning() {
  if (abort.signal.aborted) throw new FixtureFailure("interrupted");
  if (child && (child.exitCode !== null || child.signalCode !== null)) throw new FixtureFailure("signal_exited");
}

async function pause(milliseconds: number) {
  await new Promise<void>((wake) => setTimeout(wake, milliseconds));
  requireRunning();
}

async function freePort(): Promise<number> {
  const server = createNetServer();
  await new Promise<void>((listening, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", listening);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new FixtureFailure("fixture_failed");
  await new Promise<void>((closed, reject) => server.close((error) => (error ? reject(error) : closed())));
  return address.port;
}

// Export only error codes. TLS errors can include private fixture paths and provider diagnostics.
function errorCode(error: Error): string {
  return "code" in error && typeof error.code === "string" ? error.code : "REQUEST_FAILED";
}

function probe(url: string, certificate?: Buffer): Promise<Probe> {
  const start = performance.now();
  return new Promise((finish) => {
    const agent = certificate ? new HttpsAgent({ ca: certificate, keepAlive: false }) : null;
    const done = (status: number | null, code: string | null) => {
      agent?.destroy();
      finish({ ok: status === 200, status, errorCode: code, durationMs: performance.now() - start });
    };
    const receive = (response: import("node:http").IncomingMessage) => {
      const status = response.statusCode ?? null;
      response.resume();
      response.once("end", () => done(status, null));
      response.once("error", (error) => done(null, errorCode(error)));
    };
    const request = agent ? httpsGet(url, { agent }, receive) : httpGet(url, { agent: false }, receive);
    request.setTimeout(PROBE_TIMEOUT_MS, () => request.destroy(new Error("Probe timed out.")));
    request.once("error", (error) => done(null, errorCode(error)));
  });
}

async function createCertificate(directory: string) {
  const rootConfigPath = resolve(directory, "root.conf");
  const rootCertificatePath = resolve(directory, "root-certificate.pem");
  const rootKeyPath = resolve(directory, "root-key.pem");
  const requestConfigPath = resolve(directory, "request.conf");
  const requestPath = resolve(directory, "certificate.csr");
  const extensionsPath = resolve(directory, "certificate.ext");
  const certificatePath = resolve(directory, "certificate.pem");
  const keyPath = resolve(directory, "private-key.pem");
  await writeFile(
    rootConfigPath,
    "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=OpenBot E2E Root\n[ext]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n",
    { mode: 0o600 },
  );
  await writeFile(requestConfigPath, "[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=localhost\n", {
    mode: 0o600,
  });
  await writeFile(
    extensionsPath,
    "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n",
    { mode: 0o600 },
  );
  const runOpenSsl = (arguments_: string[]) =>
    new Promise<void>((done, reject) => {
      const openssl = spawn("openssl", arguments_, { stdio: "ignore" });
      openssl.once("error", () => reject(new FixtureFailure("fixture_failed")));
      openssl.once("exit", (code) => (code === 0 ? done() : reject(new FixtureFailure("fixture_failed"))));
    });
  await runOpenSsl([
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    rootKeyPath,
    "-out",
    rootCertificatePath,
    "-days",
    "1",
    "-sha256",
    "-config",
    rootConfigPath,
  ]);
  await runOpenSsl([
    "req",
    "-new",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-keyout",
    keyPath,
    "-out",
    requestPath,
    "-config",
    requestConfigPath,
  ]);
  await runOpenSsl([
    "x509",
    "-req",
    "-in",
    requestPath,
    "-CA",
    rootCertificatePath,
    "-CAkey",
    rootKeyPath,
    "-CAcreateserial",
    "-out",
    certificatePath,
    "-days",
    "1",
    "-sha256",
    "-extfile",
    extensionsPath,
  ]);
  await chmod(rootKeyPath, 0o600);
  await chmod(keyPath, 0o600);
  let expiredCertificate: Buffer | null = null;
  if (scenario === "expired-certificate") {
    const expiredCertificatePath = resolve(directory, "expired-certificate.pem");
    const databasePath = resolve(directory, "issuer-index.txt");
    const serialPath = resolve(directory, "issuer-serial.txt");
    const issuerConfigPath = resolve(directory, "issuer.conf");
    await writeFile(databasePath, "", { mode: 0o600 });
    await writeFile(serialPath, "02\n", { mode: 0o600 });
    await writeFile(
      issuerConfigPath,
      `[ca]\ndefault_ca=fixture\n[fixture]\ndatabase=${databasePath}\nnew_certs_dir=${directory}\ncertificate=${rootCertificatePath}\nprivate_key=${rootKeyPath}\nserial=${serialPath}\ndefault_md=sha256\npolicy=subject\n[subject]\ncommonName=supplied\n`,
      { mode: 0o600 },
    );
    // Explicit dates work with both LibreSSL and OpenSSL. The same CSR preserves the leaf key
    // and SANs; only validity and serial differ from the valid initial certificate.
    await runOpenSsl([
      "ca",
      "-batch",
      "-notext",
      "-config",
      issuerConfigPath,
      "-in",
      requestPath,
      "-out",
      expiredCertificatePath,
      "-extfile",
      extensionsPath,
      "-startdate",
      "20000101000000Z",
      "-enddate",
      "20000102000000Z",
    ]);
    expiredCertificate = await readFile(expiredCertificatePath);
  }
  // Trust the private root only. The listener serves a signed leaf with its loopback SANs.
  return { certificatePath, keyPath, trustedRootCertificate: await readFile(rootCertificatePath), expiredCertificate };
}

async function authenticate(socket: WebSocket, token: string) {
  await new Promise<void>((done, reject) => {
    const timer = setTimeout(() => finish(false), 10_000);
    const finish = (success: boolean) => {
      clearTimeout(timer);
      socket.off("open", hello);
      socket.off("message", message);
      socket.off("close", closed);
      if (success) done();
      else reject(new FixtureFailure("peer_authentication_failed"));
    };
    const hello = () => socket.send(JSON.stringify({ type: "hello", version: 1, peer: "host", token }));
    const closed = () => finish(false);
    const message = (data: WebSocket.RawData) => {
      try {
        const frame = decodeSignalServerMessage(JSON.parse(data.toString()));
        if (frame?.type === "ready") finish(true);
      } catch {
        // The protocol owner remains responsible for decoding. No frame or resume token is saved.
      }
    };
    socket.once("open", hello);
    socket.on("message", message);
    socket.once("close", closed);
  });
}

async function peerResponds(socket: WebSocket): Promise<boolean> {
  if (socket.readyState !== WebSocket.OPEN) return false;
  const nonce = randomUUID();
  return new Promise((done) => {
    const timer = setTimeout(() => finish(false), PROBE_TIMEOUT_MS);
    const finish = (success: boolean) => {
      clearTimeout(timer);
      socket.off("pong", pong);
      socket.off("close", closed);
      done(success);
    };
    const pong = (data: Buffer) => {
      if (data.toString() === nonce) finish(true);
    };
    const closed = () => finish(false);
    socket.on("pong", pong);
    socket.once("close", closed);
    socket.ping(nonce, undefined, (error) => {
      if (error) finish(false);
    });
  });
}

async function stopOwnedChild(owned: ChildProcess): Promise<boolean> {
  if (owned.exitCode !== null || owned.signalCode !== null) return true;
  const exited = new Promise<boolean>((done) => owned.once("exit", () => done(true)));
  owned.kill("SIGTERM");
  if (await Promise.race([exited, new Promise<false>((done) => setTimeout(() => done(false), 5_000))])) return true;
  owned.kill("SIGKILL");
  return Promise.race([exited, new Promise<false>((done) => setTimeout(() => done(false), 2_000))]);
}

try {
  for (const path of [
    "remote/api/src/index.ts",
    "remote/api/src/app.ts",
    "remote/api/src/config.ts",
    "remote/api/src/signal-service.ts",
    "scripts/signal-tls-renewal-e2e.ts",
  ]) {
    sourceHashes[path] = createHash("sha256")
      .update(await readFile(resolve(ROOT, path)))
      .digest("hex");
  }
  fixture = await mkdtemp(resolve(tmpdir(), "openbot-tls-renewal-"));
  await chmod(fixture, 0o700);
  const tls = await createCertificate(fixture);
  const signalPort = await freePort();
  const healthPort = await freePort();
  const turnPort = await freePort();
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const publicJwk = { ...(await exportJWK(publicKey)), kid: "tls-e2e", alg: "ES256", use: "sig" };
  controlPlane = createServer((request, response) => {
    request.resume();
    // Only the account validation boundary is faked; TLS, the Signal listener and ticket
    // verification run unmodified. All destinations are loopback, with no platform integrations.
    response.writeHead(request.url === "/v2/remote/resume/validate" ? 200 : 404, {
      "Content-Type": "application/json",
    });
    response.end(request.url === "/v2/remote/resume/validate" ? '{"valid":true}' : "{}");
  });
  await new Promise<void>((listening, reject) => {
    controlPlane?.once("error", reject);
    controlPlane?.listen(0, "127.0.0.1", listening);
  });
  const accountAddress = controlPlane.address();
  if (!accountAddress || typeof accountAddress === "string") throw new FixtureFailure("fixture_failed");
  child = spawn(process.execPath, [resolve(ROOT, "remote/api/src/index.ts")], {
    cwd: resolve(ROOT, "remote/api"),
    env: {
      PATH: process.env.PATH ?? "",
      HOME: process.env.HOME ?? "",
      REMOTE_SIGNAL_HOST: "127.0.0.1",
      REMOTE_SIGNAL_PORT: String(signalPort),
      REMOTE_HEALTH_HOST: "127.0.0.1",
      REMOTE_HEALTH_PORT: String(healthPort),
      REMOTE_TLS_CERT_PATH: tls.certificatePath,
      REMOTE_TLS_KEY_PATH: tls.keyPath,
      REMOTE_TICKET_PUBLIC_KEYS: JSON.stringify({ keys: [publicJwk] }),
      REMOTE_CONTROL_PLANE_URL: `http://127.0.0.1:${accountAddress.port}`,
      REMOTE_SESSION_SECRET: randomBytes(32).toString("base64url"),
      REMOTE_AUTH_WEBHOOK_SECRET: randomBytes(32).toString("base64url"),
      TURN_SHARED_SECRET: randomBytes(32).toString("base64url"),
      TURN_HOST: "127.0.0.1",
      TURN_PORT: String(turnPort),
      OPENBOT_SOURCE_COMMIT: "tls-renewal-e2e",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  // Keep at most a partial line in memory, never export raw service output.
  const observeOutput = () => {
    let partial = "";
    return (chunk: Buffer) => {
      partial = `${partial}${chunk.toString()}`.slice(-8_192);
      if (!observed.renewal && partial.includes("OpenBot Remote API reloaded its TLS certificate.")) {
        observed.renewal = { outcome: "accepted", observedAt: Date.now() };
      }
      if (!observed.renewal && partial.includes("OpenBot Remote API could not reload its TLS certificate.")) {
        observed.renewal = { outcome: "rejected", observedAt: Date.now() };
      }
      const lastNewline = partial.lastIndexOf("\n");
      if (lastNewline >= 0) partial = partial.slice(lastNewline + 1);
    };
  };
  child.stdout?.on("data", observeOutput());
  child.stderr?.on("data", observeOutput());
  child.once("error", () => abort.abort());
  const tlsUrl = `https://127.0.0.1:${signalPort}/health/live`;
  const healthUrl = `http://127.0.0.1:${healthPort}/health/ready`;
  const startupDeadline = Date.now() + STARTUP_DEADLINE_MS;
  while (Date.now() < startupDeadline) {
    requireRunning();
    beforeTls = await probe(tlsUrl, tls.trustedRootCertificate);
    beforeHealth = await probe(healthUrl);
    if (beforeTls.ok && beforeHealth.ok) break;
    await pause(200);
  }
  if (!beforeTls?.ok || !beforeHealth?.ok) throw new FixtureFailure("signal_startup_failed");
  const now = Math.floor(Date.now() / 1_000);
  const hostId = `host-${runId}`;
  const token = await new SignJWT({
    jti: randomUUID(),
    sessionId: `session-${runId}`,
    hostId,
    userId: `owner-${runId}`,
    membershipId: `${hostId}:host`,
    role: "host",
    authEpoch: 1,
    protocolMinimum: REMOTE_TICKET_PROTOCOL_VERSION,
    protocolMaximum: REMOTE_TICKET_PROTOCOL_VERSION,
    sessionExpiresAt: now + 86_400,
  })
    .setProtectedHeader({ alg: "ES256", kid: "tls-e2e" })
    .setAudience(REMOTE_TICKET_AUDIENCE)
    .setIssuedAt(now - 5)
    .setExpirationTime(now + 120)
    .sign(privateKey);
  // Bun's ws adapter extracts TLS trust from the agent; top-level ws `ca` is not forwarded.
  peerAgent = new HttpsAgent({ ca: tls.trustedRootCertificate });
  peer = new WebSocket(`wss://127.0.0.1:${signalPort}/v1/signal`, { agent: peerAgent });
  peer.on("error", () => {});
  peer.once("close", (code) => {
    closedCode = code;
  });
  await authenticate(peer, token);
  ready = true;
  pingTimer = setInterval(() => {
    if (peer?.readyState === WebSocket.OPEN) peer.ping();
  }, 20_000);
  if (scenario === "expired-certificate") {
    if (!tls.expiredCertificate) throw new FixtureFailure("fixture_failed");
    const initial = new X509Certificate(await readFile(tls.certificatePath));
    const expired = new X509Certificate(tls.expiredCertificate);
    const trustedRoot = new X509Certificate(tls.trustedRootCertificate);
    const now = Date.now();
    stagedCertificate = {
      validFrom: expired.validFrom,
      validTo: expired.validTo,
      expiredBeforeReplacement: Date.parse(expired.validTo) < now,
      matchesPrivateKey: expired.checkPrivateKey(createPrivateKey(await readFile(tls.keyPath))),
      signedByTrustedRoot: expired.verify(trustedRoot.publicKey),
      loopbackSANValid: expired.checkIP("127.0.0.1") === "127.0.0.1",
      initialValidBeyondRenewalDeadline:
        Date.parse(initial.validFrom) <= now && Date.parse(initial.validTo) > now + RENEWAL_DEADLINE_MS,
    };
    if (
      !stagedCertificate.expiredBeforeReplacement ||
      !stagedCertificate.matchesPrivateKey ||
      !stagedCertificate.signedByTrustedRoot ||
      !stagedCertificate.loopbackSANValid ||
      !stagedCertificate.initialValidBeyondRenewalDeadline
    )
      throw new FixtureFailure("fixture_failed");
    await writeFile(tls.certificatePath, tls.expiredCertificate, { mode: 0o600 });
  } else {
    const replacement = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({
      type: "pkcs8",
      format: "pem",
    });
    await writeFile(tls.keyPath, replacement, { mode: 0o600 });
  }
  fixtureKeyReplacedAt = Date.now();
  const renewalDeadline = fixtureKeyReplacedAt + RENEWAL_DEADLINE_MS;
  while (!observed.renewal && Date.now() < renewalDeadline) await pause(250);
  requireRunning();
  if (!observed.renewal) throw new FixtureFailure("renewal_not_observed");
  childAliveAfterRenewal = child.exitCode === null && child.signalCode === null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    afterTls.push(await probe(tlsUrl, tls.trustedRootCertificate));
    await pause(100);
  }
  afterHealth = await probe(healthUrl);
  afterPeerPong = await peerResponds(peer);
  closedCodeAfterRenewal = closedCode;
  if (!afterTls.every((result) => result.ok)) throw new FixtureFailure("known_good_listener_lost");
  if (!afterPeerPong || closedCode !== null) throw new FixtureFailure("existing_peer_lost");
  if (!afterHealth.ok) throw new FixtureFailure("readiness_not_truthful");
} catch (error) {
  failure = error instanceof FixtureFailure ? error.code : "fixture_failed";
} finally {
  if (pingTimer) clearInterval(pingTimer);
  peer?.terminate();
  peerAgent?.destroy();
  if (child) childStopped = await stopOwnedChild(child);
  if (controlPlane) {
    controlPlane.closeAllConnections();
    await new Promise<void>((closed) => controlPlane?.close(() => closed()));
  }
  if (fixture) {
    try {
      await rm(fixture, { recursive: true });
    } catch {
      fixtureRemoved = false;
    }
  }
  process.off("SIGINT", onInterrupt);
  process.off("SIGTERM", onInterrupt);
}

const passed = failure === null && childStopped && fixtureRemoved;
await writeFile(
  resolve(output, "report.json"),
  `${JSON.stringify(
    {
      runId,
      scenario:
        scenario === "expired-certificate"
          ? "expired-staged-certificate-preserves-working-signal-listener"
          : "mismatched-staged-key-preserves-working-signal-listener",
      passed,
      failure,
      runtime: {
        binary: basename(process.execPath),
        versions: { bun: process.versions.bun, node: process.versions.node },
      },
      sourceHashes,
      startedAt: new Date(startedAt).toISOString(),
      durationMs: Date.now() - startedAt,
      renewal: observed.renewal
        ? {
            outcome: observed.renewal.outcome,
            elapsedSinceStagedReplacementMs:
              fixtureKeyReplacedAt === null ? null : observed.renewal.observedAt - fixtureKeyReplacedAt,
          }
        : null,
      observation: {
        stagedCertificate,
        authenticatedBeforeReplacement: ready,
        beforeTls,
        beforeHealth,
        afterTls,
        afterHealth,
        childAliveAfterRenewal,
        existingPeerPong: afterPeerPong,
        existingPeerCloseCode: closedCodeAfterRenewal,
        readinessFalselyReady:
          afterHealth?.ok === true && afterTls.length > 0 && afterTls.every((result) => !result.ok),
      },
      cleanup: { childStopped, fixtureRemoved },
      limits: [
        "Uses the real Signal entry point and natural five-minute renewal interval with loopback fixtures.",
        "Does not exercise a successful certificate rotation, production certificates, TURN delivery or hosted availability.",
      ],
    },
    null,
    2,
  )}\n`,
  { mode: 0o600 },
);
process.stdout.write(
  `${JSON.stringify({ passed, failure, report: relative(ROOT, resolve(output, "report.json")) })}\n`,
);
process.exitCode = passed ? 0 : 1;
