\# GI/PPI — RUNS CONTRACT (CANONICAL)



Authority Level: Binding Local Custody Spec  

Status: BINDING | NON-OPTIONAL  

Scope: Local run bundles created by tools/pwsh scripts  

Non-goal: This does not define UI, chat, agents, or execution engines.



\## 1. Purpose



A "run bundle" is the local, append-only custody artifact for a single evaluation attempt.

It exists to provide audit-grade evidence of:



\- what was proposed

\- what was transmitted

\- what was returned

\- when it happened

\- which policy version was used



The run bundle is NOT the source of truth for the ledger.

The ledger is the database.

The run bundle is the operator’s local custody copy.



\## 2. Directory Structure



All run bundles live under:



runs/YYYYMMDD/eval\_YYYYMMDDTHHMMSSZ\_<run\_uuid>/



Example:



runs/20260118/eval\_20260118T175215Z\_8d88b3f3-0ac7-4ae5-9fa0-3b3b0e0b2c9a/



\## 3. Required Files (V0)



Each run bundle MUST contain these files:



\- proposal.json

\- rpc\_request.json

\- rpc\_response.json

\- summary.json



If any required file is missing, the bundle is non-canonical.



\## 4. File Semantics



\### 4.1 proposal.json



The proposal object (GI\_PPI\_PROPOSAL\_V0) exactly as constructed before submission.



\### 4.2 rpc\_request.json



The exact JSON body sent to the database RPC.

Must include:



\- p\_policy\_version\_id

\- p\_proposal (object)



\### 4.3 rpc\_response.json



The exact JSON returned by the RPC.



\### 4.4 summary.json



A minimal, operator-friendly index:



\- run\_id

\- created\_at\_utc

\- policy\_version\_id

\- evaluation\_id

\- decision

\- reason\_codes

\- proposal\_hash



\## 5. Append-only Rule



Run bundles are append-only.

Tools MUST NOT modify existing bundles.

If a rerun is needed, create a new bundle.



\## 6. Canonical Naming



\- All filenames are fixed and lowercase.

\- Bundle folder prefix is "eval\_".

\- Timestamp format is UTC: YYYYMMDDTHHMMSSZ.



\## 7. Optional Files (V0)



Allowed but not required:



\- error.json (if the RPC fails; contains error payload and context)

\- notes.txt (operator notes)



No other files are permitted without versioning this contract.



\## 8. Contract Versioning



Any change to required files or semantics requires a contract bump:



RUNS\_CONTRACT\_V0 → RUNS\_CONTRACT\_V1, etc.



