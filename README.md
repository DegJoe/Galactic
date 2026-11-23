# SaleSpark v0.2 — Stage 1 (foundation)
- `legacy-prototype/` original single-file prototype (kept, untouched).
- `src/money.js` payment/change/repayment logic (integer pesewas). `npm test` runs 12 passing tests.
- `supabase/schema.sql` tables, RLS, atomic `record_sale` / `record_repayment` / `restock`. **Not yet run against a database.**
Not built yet: PWA UI, auth screens, reports/exports, receipts, backups, Vercel config.
