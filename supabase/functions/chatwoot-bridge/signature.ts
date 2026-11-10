// Chatwoot webhook signature check.
//
// Per Chatwoot's webhook docs, signed deliveries carry:
//   X-Chatwoot-Timestamp: <timestamp>
//   X-Chatwoot-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<raw request body>", keyed with the webhook secret>
//
// Uses only Web Crypto, so it runs in Deno (Supabase Edge Functions) and Node alike.

export type SignatureResult =
  | { ok: true }
  | { ok: false; reason: "missing_headers" | "bad_timestamp" | "stale_timestamp" | "bad_signature_format" | "mismatch" };

const enc = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

// Compare without bailing out at the first differing character.
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return toHex(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
}

// Accepts unix seconds, or milliseconds (values above 1e12), as a number or numeric string.
export function parseTimestampSeconds(raw: string): number | null {
  if (!/^\d{9,13}$/.test(raw.trim())) return null;
  const n = Number(raw.trim());
  return n > 1e12 ? Math.floor(n / 1000) : n;
}

export async function verifyChatwootSignature(args: {
  secret: string;
  timestampHeader: string | null;
  signatureHeader: string | null;
  rawBody: string;
  nowSeconds: number;
  toleranceSeconds?: number;
}): Promise<SignatureResult> {
  const { secret, timestampHeader, signatureHeader, rawBody, nowSeconds } = args;
  const tolerance = args.toleranceSeconds ?? 300;

  if (!timestampHeader || !signatureHeader) return { ok: false, reason: "missing_headers" };

  const ts = parseTimestampSeconds(timestampHeader);
  if (ts === null) return { ok: false, reason: "bad_timestamp" };
  if (Math.abs(nowSeconds - ts) > tolerance) return { ok: false, reason: "stale_timestamp" };

  const m = /^sha256=([0-9a-f]{64})$/i.exec(signatureHeader.trim());
  if (!m) return { ok: false, reason: "bad_signature_format" };

  // Sign the timestamp exactly as it arrived (not the parsed number) so formatting differences cannot break the match.
  const expected = await hmacSha256Hex(secret, `${timestampHeader.trim()}.${rawBody}`);
  return timingSafeEqual(expected, m[1].toLowerCase()) ? { ok: true } : { ok: false, reason: "mismatch" };
}
