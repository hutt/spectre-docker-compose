// Erzeugt ein Admin-JWT für Ghost 6.x aus "id:secret".
// Liest entweder aus ENV GHOST_ADMIN_API_KEY oder STDIN.
import fs from "node:fs";
import jwt from "jsonwebtoken";

const input = process.env.GHOST_ADMIN_API_KEY || fs.readFileSync(0, "utf8").trim();
if (!input.includes(":")) {
  console.error("Expected GHOST_ADMIN_API_KEY in format id:secret");
  process.exit(2);
}
const [id, secret] = input.split(":");
const iat = Math.floor(Date.now() / 1000);
const token = jwt.sign(
  { iat, exp: iat + 5 * 60, aud: "/admin/" },
  Buffer.from(secret, "hex"),
  { header: { kid: id }, algorithm: "HS256" }
);
process.stdout.write(token);
