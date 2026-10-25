import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { config, root } from "./config.js";

let keyPromise: Promise<Buffer> | undefined;
function key() {
  return (keyPromise ??= (async () => {
    if (process.env.ENCRYPTION_KEY) {
      const value = Buffer.from(process.env.ENCRYPTION_KEY, "hex");
      if (value.length !== 32)
        throw new Error(
          "ENCRYPTION_KEY must contain 64 hexadecimal characters.",
        );
      return value;
    }
    if (config.production)
      throw new Error("ENCRYPTION_KEY is required for production MFA.");
    await mkdir(path.join(root, ".local"), { recursive: true });
    const file = path.join(root, ".local/encryption-key");
    try {
      await writeFile(file, randomBytes(32).toString("hex"), {
        flag: "wx",
        mode: 0o600,
      });
    } catch (e: any) {
      if (e.code !== "EEXIST") throw e;
    }
    return Buffer.from(await readFile(file, "utf8"), "hex");
  })());
}
export async function encryptSecret(secret: string) {
  const iv = randomBytes(12),
    cipher = createCipheriv("aes-256-gcm", await key(), iv);
  const encrypted = Buffer.concat([
    cipher.update(secret, "utf8"),
    cipher.final(),
  ]);
  return [iv, cipher.getAuthTag(), encrypted]
    .map((v) => v.toString("base64"))
    .join(".");
}
export async function decryptSecret(encoded: string) {
  const [iv, tag, data] = encoded
    .split(".")
    .map((v) => Buffer.from(v, "base64"));
  const decipher = createDecipheriv("aes-256-gcm", await key(), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(data), decipher.final()]).toString(
    "utf8",
  );
}
function base32(secret: string) {
  let bits = "";
  for (const c of secret.toUpperCase().replaceAll("=", "")) {
    const n = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(c);
    if (n < 0) throw new Error("Invalid TOTP secret.");
    bits += n.toString(2).padStart(5, "0");
  }
  return Buffer.from((bits.match(/.{8}/g) ?? []).map((b) => parseInt(b, 2)));
}
export function totp(secret: string, counter = Math.floor(Date.now() / 30000)) {
  const data = Buffer.alloc(8);
  data.writeBigUInt64BE(BigInt(counter));
  const hash = createHmac("sha1", base32(secret)).update(data).digest(),
    offset = hash[19] & 15;
  return ((hash.readUInt32BE(offset) & 0x7fffffff) % 1000000)
    .toString()
    .padStart(6, "0");
}
export function verifyTotp(
  secret: string,
  code: string,
  lastCounter: number | null,
) {
  if (!/^\d{6}$/.test(code)) return null;
  const now = Math.floor(Date.now() / 30000);
  for (const counter of [now, now - 1, now + 1])
    if (
      counter > (lastCounter ?? -1) &&
      timingSafeEqual(Buffer.from(code), Buffer.from(totp(secret, counter)))
    )
      return counter;
  return null;
}
