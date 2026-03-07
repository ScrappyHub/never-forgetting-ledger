-- ============================================
-- GI/PPI Reason Codes for Entitlements (V0)
-- File: sql/ops/140_reason_codes_for_entitlements.sql
-- ============================================

insert into public.governance_reason_codes (code, severity, description)
values
  ('credits_exhausted','deny','Org has insufficient credits to authorize an ALLOW evaluation spend.'),
  ('eval_allow_spend_v0','info','Credit spend event recorded for an ALLOW evaluation (ledger reason).')
on conflict (code) do nothing;
