// src/lib/client/downloadLicenseFile.ts

type Params = {
  functionsBaseUrl: string;     // e.g. https://hmlihkcijjamxdurydbv.functions.supabase.co
  accessToken: string;          // user JWT from your auth session
  orgId: string;
  artifactKey: string;          // work-engine-windows / work-engine-mac / work-engine-linux
};

export async function downloadLicenseFile(params: Params) {
  const { functionsBaseUrl, accessToken, orgId, artifactKey } = params;

  const res = await fetch(`${functionsBaseUrl}/license-file`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "authorization": `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      org_id: orgId,
      artifact_key: artifactKey,
    }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`license-file failed (${res.status}): ${text}`);
  }

  const blob = await res.blob();
  const filename = `gi-ppi-license-${artifactKey}.license.json`;

  const url = window.URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.URL.revokeObjectURL(url);
}
