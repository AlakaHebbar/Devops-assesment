type Level = "info" | "warn" | "error";

// One JSON object per line on stdout/stderr. Fluent Bit tails container output,
// merges these fields into the record and ships it to the S3 log archive.
export function log(level: Level, event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({
    timestamp: new Date().toISOString(),
    level,
    event,
    version: process.env.APP_VERSION ?? "dev",
    ...fields,
  });

  if (level === "info") {
    console.info(line);
  } else {
    console.error(line);
  }
}
