#!/usr/bin/env python3
"""
_selftest_nfl_export_v1.py - portable negative proof for verify_nfl_export_v1.py.

Self-contained: builds throwaway ed25519 keys, exports, and trust bundles in a temp
dir, runs the real verifier, and asserts each attack is rejected. Requires python3 +
OpenSSH (ssh-keygen). Never touches the real ledger or key.

Cases:
  PIN_CLEAN            trusted-pub pin, good bundle          -> NFL_EXPORT_VERIFY_OK
  PIN_WRONG_KEY        trusted-pub is a different key        -> SIG_INVALID
  TAMPER_RECORD        mutate a record                       -> EXPORT_HEAD_MISMATCH
  BUNDLE_OK            signer authorized for namespace       -> NFL_EXPORT_VERIFY_OK
  BUNDLE_UNKNOWN_KEY   signer not in bundle                  -> SIGNER_NOT_IN_BUNDLE
  BUNDLE_WRONG_NS      signer present, namespace not listed  -> NAMESPACE_NOT_AUTHORIZED
"""
import os, sys, json, hashlib, subprocess, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFIER = os.path.join(HERE, "verify_nfl_export_v1.py")
GEN = "nfl.ledger.export.v1"
NS = "nfl/ledger-export-seal"

def sh(s): return hashlib.sha256(s.encode()).hexdigest()

def run(*args):
    return subprocess.run([sys.executable, VERIFIER] + list(args), capture_output=True, text=True)

def genkey(path):
    subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", path, "-N", "", "-C", "selftest", "-q"], check=True)

def build_export(d, key, ns, identity):
    os.makedirs(d, exist_ok=True)
    recs = [{"hash": "aaa1", "artifact": "one", "timestamp": "2026-01-01T00:00:00Z"},
            {"hash": "bbb2", "artifact": "two", "timestamp": "2026-01-02T00:00:00Z"}]
    with open(os.path.join(d, "records.ndjson"), "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(json.dumps(r, separators=(",", ":")) for r in recs) + "\n")
    head = ""
    for i, r in enumerate(recs):
        rh = sh("hash=" + r["hash"] + "\nartifact=" + r["artifact"] + "\ntimestamp=" + r["timestamp"])
        head = sh((GEN + "\n" + rh) if i == 0 else (head + "\n" + rh))
    ledsha = sh("dummy")
    with open(os.path.join(d, "export_payload.txt"), "w", encoding="utf-8", newline="") as f:
        f.write(GEN + "\ncount=2\nexport_head=" + head + "\nledger_sha256=" + ledsha + "\n")
    man = dict(schema=GEN, utc="x", export_algo="sha256-linked-fieldkv-v1", genesis=GEN, count=2,
               export_head=head, ledger_sha256=ledsha, signer_identity=identity, namespace=ns,
               records_file="records.ndjson", payload_file="export_payload.txt",
               signature_file="export_payload.txt.sig", public_key_file="signer.pub",
               allowed_signers_file="allowed_signers")
    with open(os.path.join(d, "export_manifest.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(man, indent=2))
    subprocess.run(["ssh-keygen", "-Y", "sign", "-f", key, "-n", ns,
                    os.path.join(d, "export_payload.txt")],
                   capture_output=True, check=True)
    shutil.copyfile(key + ".pub", os.path.join(d, "signer.pub"))
    with open(os.path.join(d, "allowed_signers"), "w", encoding="utf-8", newline="") as f:
        f.write(identity + " " + open(key + ".pub").read().strip() + "\n")
    return head

def bundle(path, pubfile, namespaces):
    pub = open(pubfile).read().strip()
    b = {"schema": "neverlost.trust_bundle.v1", "created_utc": "x",
         "principals": [{"principal": "single-tenant/local/authority/nfl",
                         "keys": [{"key_id": "k1", "pubkey": pub, "namespaces": namespaces}]}]}
    open(path, "w").write(json.dumps(b, indent=2))

def main():
    tmp = tempfile.mkdtemp(prefix="nfl_export_selftest_")
    results = []
    def check(name, cond, detail=""):
        results.append((name, cond))
        print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail else ""))
    try:
        genkey(os.path.join(tmp, "main"))
        genkey(os.path.join(tmp, "evil"))
        exp = os.path.join(tmp, "exp_main"); build_export(exp, os.path.join(tmp, "main"), NS, "nfl.local")
        expe = os.path.join(tmp, "exp_evil"); build_export(expe, os.path.join(tmp, "evil"), NS, "nfl.local")
        bundle(os.path.join(tmp, "b_ok.json"), os.path.join(tmp, "main.pub"), [NS])
        bundle(os.path.join(tmp, "b_wrongns.json"), os.path.join(tmp, "main.pub"), ["nfl/other"])

        r = run(exp, "--trusted-pub", os.path.join(tmp, "main.pub"))
        check("PIN_CLEAN", r.returncode == 0 and "NFL_EXPORT_VERIFY_OK" in r.stdout, "rc=%d" % r.returncode)

        r = run(exp, "--trusted-pub", os.path.join(tmp, "evil.pub"))
        check("PIN_WRONG_KEY", r.returncode == 1 and "SIG_INVALID" in r.stdout, "rc=%d" % r.returncode)

        tdir = os.path.join(tmp, "exp_tamper"); shutil.copytree(exp, tdir)
        p = os.path.join(tdir, "records.ndjson")
        tampered = open(p, encoding="utf-8").read().replace('"two"', '"two-EVIL"')
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(tampered)
        r = run(tdir, "--trusted-pub", os.path.join(tmp, "main.pub"))
        check("TAMPER_RECORD", r.returncode == 1 and "EXPORT_HEAD_MISMATCH" in r.stdout, "rc=%d" % r.returncode)

        r = run(exp, "--trust-bundle", os.path.join(tmp, "b_ok.json"))
        check("BUNDLE_OK", r.returncode == 0 and "NFL_EXPORT_VERIFY_OK" in r.stdout, "rc=%d" % r.returncode)

        r = run(expe, "--trust-bundle", os.path.join(tmp, "b_ok.json"))
        check("BUNDLE_UNKNOWN_KEY", r.returncode == 1 and "SIGNER_NOT_IN_BUNDLE" in r.stdout, "rc=%d" % r.returncode)

        r = run(exp, "--trust-bundle", os.path.join(tmp, "b_wrongns.json"))
        check("BUNDLE_WRONG_NS", r.returncode == 1 and "NAMESPACE_NOT_AUTHORIZED" in r.stdout, "rc=%d" % r.returncode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    passed = sum(1 for _, ok in results if ok)
    total = len(results)
    print("RESULT=%d/%d" % (passed, total))
    if passed != total:
        print("NFL_EXPORT_SELFTEST_FAIL")
        sys.exit(1)
    print("NFL_EXPORT_SELFTEST_OK")

if __name__ == "__main__":
    main()
