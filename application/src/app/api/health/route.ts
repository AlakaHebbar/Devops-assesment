export const dynamic = "force-dynamic";

// Polled by the kubelet (readiness/liveness), the ALB and the Argo CD smoke
// test, hundreds of times an hour per pod. A successful check is deliberately
// not logged, so it doesn't drown real events in the S3 log archive.
export function GET() {
  return Response.json(
    {
      status: "ok",
      version: process.env.APP_VERSION ?? "dev",
      checkedAt: new Date().toISOString(),
    },
    {
      status: 200,
      headers: { "Cache-Control": "no-store" },
    },
  );
}
