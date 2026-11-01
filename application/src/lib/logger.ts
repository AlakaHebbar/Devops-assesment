type HealthLog = {
  status: "ok";
  checkedAt: string;
};

export function logHealth({ status, checkedAt }: HealthLog): void {
  console.info(
    JSON.stringify({
      timestamp: checkedAt,
      level: "info",
      event: "health_check",
      status,
    }),
  );
}
