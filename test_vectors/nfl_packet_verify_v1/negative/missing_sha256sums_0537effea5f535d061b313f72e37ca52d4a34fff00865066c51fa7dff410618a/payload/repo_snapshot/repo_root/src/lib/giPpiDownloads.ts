// src/lib/giPpiDownloads.ts

export type DownloadUrlResponse =
  | {
      ok: true;
      org_id: string;
      artifact_key: string;
      plan_code: string;
      filename: string;
      signed_url: string;
      expires_in_seconds: number;
    }
  | {
      ok: false;
      error: string;
      message?: string;
    };

export async function getSignedDownloadUrl(opts: {
  functionsBaseUrl: string;     // https://hmlihkcijjamxdurydbv.functions.supabase.co
  accessToken: string;          // user JWT
  orgId: string;
  artifactKey: string;
  expiresInSeconds?: number;    // default 300
}): Promise<DownloadUrlResponse> {
  const res = await fetch(`${opts.functionsBaseUrl}/download-url`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${opts.accessToken}`,
    },
    body: JSON.stringify({
      org_id: opts.orgId,
      artifact_key: opts.artifactKey,
      expires_in_seconds: opts.expiresInSeconds ?? 300,
    }),
  });

  const data = (await res.json().catch(() => null)) as DownloadUrlResponse | null;
  if (!data) throw new Error(`download-url failed: empty response (${res.status})`);
  if (!res.ok) throw new Error(`download-url failed (${res.status}): ${JSON.stringify(data)}`);
  return data;
}

export async function forceDownloadBySignedUrl(signedUrl: string) {
  // This triggers a real browser download, not a SPA navigation.
  const a = document.createElement("a");
  a.href = signedUrl;
  a.rel = "noreferrer";
  a.target = "_blank";
  document.body.appendChild(a);
  a.click();
  a.remove();
}
