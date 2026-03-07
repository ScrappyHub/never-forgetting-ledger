"use client";

import React, { useState } from "react";
import { downloadLicenseFile } from "@/lib/client/downloadLicenseFile";
import { getSignedDownloadUrl, forceDownloadBySignedUrl } from "@/lib/giPpiDownloads";

type Props = {
  functionsBaseUrl: string;  // https://hmlihkcijjamxdurydbv.functions.supabase.co
  accessToken: string;       // user JWT
  orgId: string;
  artifactKey: "work-engine-windows" | "work-engine-mac" | "work-engine-linux";
  mode?: "license" | "installer";
};

export default function DownloadLicenseButton({
  functionsBaseUrl,
  accessToken,
  orgId,
  artifactKey,
  mode = "license",
}: Props) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function onClick() {
    setErr(null);
    setBusy(true);
    try {
      if (mode === "license") {
        await downloadLicenseFile({ functionsBaseUrl, accessToken, orgId, artifactKey });
      } else {
        const r = await getSignedDownloadUrl({ functionsBaseUrl, accessToken, orgId, artifactKey });
        if (!r.ok) throw new Error(r.error);
        await forceDownloadBySignedUrl(r.signed_url);
      }
    } catch (e: any) {
      setErr(String(e?.message ?? e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ display: "grid", gap: 8 }}>
      <button
        onClick={onClick}
        disabled={busy}
        style={{
          padding: "10px 14px",
          borderRadius: 10,
          border: "1px solid rgba(255,255,255,0.15)",
          background: "rgba(255,255,255,0.06)",
          cursor: busy ? "not-allowed" : "pointer",
        }}
      >
        {busy
          ? "Working..."
          : mode === "license"
          ? `Download license (${artifactKey})`
          : `Download installer (${artifactKey})`}
      </button>

      {err ? (
        <div style={{ color: "#ffb4b4", fontSize: 13, whiteSpace: "pre-wrap" }}>
          {err}
        </div>
      ) : null}
    </div>
  );
}
