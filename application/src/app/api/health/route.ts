import { logHealth } from "../../../lib/logger";

export const dynamic = "force-dynamic";

export function GET() {
  const checkedAt = new Date().toISOString();
  logHealth({ status: "ok", checkedAt });

  return Response.json(
    {
      status: "ok",
      checkedAt,
    },
    {
      status: 200,
      headers: { "Cache-Control": "no-store" },
    },
  );
}
