import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const namespaceId = String(process.argv[2] || "").trim();
if (!/^[a-fA-F0-9]{32}$/.test(namespaceId)) {
  console.error("Expected a 32-character Cloudflare KV namespace ID.");
  process.exit(2);
}
const base = JSON.parse(fs.readFileSync(path.join(root, "wrangler.jsonc"), "utf8"));
base.kv_namespaces = [{ binding: "OAUTH_KV", id: namespaceId }];
base.routes = [{ pattern: "auth.codefeddy.com", custom_domain: true }];
if (!base.routes.some((route) => route.pattern === "auth.codefeddy.com" && route.custom_domain === true)) {
  throw new Error("Production config must retain auth.codefeddy.com as a custom domain.");
}
fs.writeFileSync(path.join(root, "wrangler.generated.jsonc"), `${JSON.stringify(base, null, 2)}\n`);
console.log("Rendered wrangler.generated.jsonc with OAUTH_KV binding and auth.codefeddy.com custom domain.");

