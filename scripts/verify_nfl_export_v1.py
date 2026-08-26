#!/usr/bin/env python3
"""
verify_nfl_export_v1.py  -  standalone portable verifier for an NFL ledger export.

Independent of the NFL PowerShell environment. Recomputes the export chain head
from records.ndjson using the documented language-neutral canonicalization, checks
that the signed payload binds that head, and verifies the signature with ssh-keygen
(-Y verify). Works on any OS that has python3 + OpenSSH.

Usage:
  verify_nfl_export_v1.py <export_dir> [--trusted-pub PATH]

--trusted-pub PATH pins verification to an out-of-band authorized public key
(the correct security posture). Without it, the bundled signer.pub is used and a
warning is printed (proves signature integrity, not authorization).

Exit 0 and prints NFL_EXPORT_VERIFY_OK on success; else NFL_EXPORT_VERIFY_FAIL:<reason>.
"""
import sys, os, json, hashlib, subprocess, tempfile, argparse

GENESIS = "nfl.ledger.export.v1"

def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

def fail(reason: str):
    print("NFL_EXPORT_VERIFY_FAIL:" + reason)
    sys.exit(1)

def read_text(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return f.read()

def canon_record(rec) -> str:
    h = rec.get("hash", "")
    a = rec.get("artifact", "")
    if a is None:
        a = ""
    t = rec.get("timestamp", "")
    for fv in (h, a, t):
        if "\n" in fv or "\x1f" in fv:
            fail("FIELD_HAS_CONTROL_CHAR")
    return "hash=" + h + "\n" + "artifact=" + a + "\n" + "timestamp=" + t

def key_core(publine: str) -> str:
    # ssh pubkey line = "<type> <base64> [comment]"; identity is type+base64 (comment ignored)
    parts = publine.strip().split()
    return " ".join(parts[:2]) if len(parts) >= 2 else publine.strip()

def load_bundle(path):
    b = json.loads(read_text(path))
    if str(b.get("schema", "")) != "neverlost.trust_bundle.v1":
        fail("TRUST_BUNDLE_BAD_SCHEMA:" + str(b.get("schema")))
    return b

def resolve_authorized(bundle, namespace):
    """Return (authorized, all_cores): authorized = [(principal, publine)] whose key
    lists `namespace`; all_cores = set of key_core() for every key in the bundle."""
    authorized = []
    all_cores = set()
    for pr in bundle.get("principals", []):
        principal = pr.get("principal", "")
        for k in pr.get("keys", []):
            pub = k.get("pubkey", "")
            all_cores.add(key_core(pub))
            if namespace in (k.get("namespaces") or []):
                authorized.append((principal, pub))
    return authorized, all_cores

def ssh_verify(allowed_path, identity, namespace, sig_path, payload_bytes):
    return subprocess.run(
        ["ssh-keygen", "-Y", "verify", "-f", allowed_path, "-I", identity,
         "-n", namespace, "-s", sig_path],
        input=payload_bytes, capture_output=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("export_dir")
    ap.add_argument("--trusted-pub", default=None,
                    help="pin verification to this out-of-band public key")
    ap.add_argument("--trust-bundle", default=None,
                    help="authorize the signer via a neverlost.trust_bundle.v1 file "
                         "(signer must be listed for the export's namespace)")
    args = ap.parse_args()

    d = args.export_dir
    manp = os.path.join(d, "export_manifest.json")
    if not os.path.isfile(manp):
        fail("MANIFEST_MISSING")
    man = json.loads(read_text(manp))

    if man.get("export_algo") != "sha256-linked-fieldkv-v1":
        fail("UNKNOWN_ALGO:" + str(man.get("export_algo")))

    recp = os.path.join(d, man["records_file"])
    payp = os.path.join(d, man["payload_file"])
    sigp = os.path.join(d, man["signature_file"])
    if not (os.path.isfile(recp) and os.path.isfile(payp) and os.path.isfile(sigp)):
        fail("BUNDLE_SURFACE_MISSING")

    # ---- 1) recompute chain head over records ----
    records = []
    for ln in read_text(recp).split("\n"):
        ln = ln.strip()
        if not ln:
            continue
        try:
            records.append(json.loads(ln))
        except Exception:
            fail("BAD_RECORD_JSON")

    if len(records) != int(man["count"]):
        fail("COUNT_MISMATCH:manifest=%s records=%d" % (man["count"], len(records)))

    head = ""
    for i, rec in enumerate(records):
        rh = sha256_hex(canon_record(rec))
        head = sha256_hex((GENESIS + "\n" + rh) if i == 0 else (head + "\n" + rh))

    if head != man["export_head"]:
        print("MANIFEST_HEAD =", man["export_head"])
        print("RECOMPUTED    =", head)
        fail("EXPORT_HEAD_MISMATCH")
    print("CHAIN_HEAD_RECOMPUTED_OK count=%d head=%s" % (len(records), head))

    # ---- 2) signed payload must bind the recomputed head ----
    expected_payload = (GENESIS + "\n" +
                        "count=" + str(man["count"]) + "\n" +
                        "export_head=" + man["export_head"] + "\n" +
                        "ledger_sha256=" + man["ledger_sha256"] + "\n")
    with open(payp, "rb") as f:
        payload_bytes = f.read()
    if payload_bytes != expected_payload.encode("utf-8"):
        fail("PAYLOAD_DOES_NOT_BIND_HEAD")
    print("PAYLOAD_BINDS_HEAD_OK")

    # ---- 3) signature verify via ssh-keygen ----
    identity = man["signer_identity"]
    namespace = man["namespace"]

    if args.trust_bundle:
        # Authorize the signer via a neverlost.trust_bundle.v1: the signature must be
        # made by a key the bundle lists for THIS namespace. Anchor is the bundle, not
        # the seal-bundled allowed_signers.
        bundle = load_bundle(args.trust_bundle)
        authorized, all_cores = resolve_authorized(bundle, namespace)
        print("TRUST=bundle(%s) authorized_keys_for_ns=%d" % (args.trust_bundle, len(authorized)))
        ok = False
        for principal, pub in authorized:
            fd, tmp = tempfile.mkstemp(prefix="nfl_export_allowed_", suffix=".txt")
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                f.write(principal + " " + pub + "\n")
            try:
                proc = ssh_verify(tmp, principal, namespace, sigp, payload_bytes)
            finally:
                os.remove(tmp)
            if proc.returncode == 0:
                print("SIGNATURE_OK authorized_principal=%s" % principal)
                ok = True
                break
        if not ok:
            # precise reason using the bundled signer.pub (messaging only; not the anchor)
            signer_core = key_core(read_text(os.path.join(d, man["public_key_file"])))
            if signer_core not in all_cores:
                fail("SIGNER_NOT_IN_BUNDLE")
            elif signer_core not in {key_core(p) for _, p in authorized}:
                fail("NAMESPACE_NOT_AUTHORIZED")
            else:
                fail("SIG_INVALID")
    else:
        tmp_allowed = None
        if args.trusted_pub:
            pub = read_text(args.trusted_pub).strip()
            fd, tmp_allowed = tempfile.mkstemp(prefix="nfl_export_allowed_", suffix=".txt")
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                f.write(identity + " " + pub + "\n")
            allowed = tmp_allowed
            print("TRUST=pinned(%s)" % args.trusted_pub)
        else:
            allowed = os.path.join(d, man["allowed_signers_file"])
            print("TRUST=bundled(WARNING: not pinned to an out-of-band key)")
        try:
            proc = ssh_verify(allowed, identity, namespace, sigp, payload_bytes)
        finally:
            if tmp_allowed and os.path.exists(tmp_allowed):
                os.remove(tmp_allowed)
        if proc.returncode != 0:
            print("SSHKEYGEN_STDERR:", proc.stderr.decode("utf-8", "replace").strip())
            fail("SIG_INVALID")
        print("SIGNATURE_OK", proc.stdout.decode("utf-8", "replace").strip())

    print("NFL_EXPORT_VERIFY_OK")
    sys.exit(0)

if __name__ == "__main__":
    main()
