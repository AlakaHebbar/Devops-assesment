// Runs once when the Next.js server starts.
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    const { log } = await import("./lib/logger");
    log("info", "server_started", { node: process.version });
  }
}
