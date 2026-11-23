// All money is integer pesewas (GH₵1.00 = 100). Never use floats for balances.
export const toPesewas = (cedis) => Math.round(Number(cedis) * 100);
export const fmt = (p) => 'GH₵' + (p / 100).toFixed(2);

// items: [{qty, unitPesewas}], cash = cash tendered, momo = MoMo received (pesewas)
export function calcSale({ items, cash = 0, momo = 0 }) {
  if (!items?.length) throw new Error('No items');
  let total = 0;
  for (const i of items) {
    if (!(i.qty > 0) || !Number.isInteger(i.unitPesewas) || i.unitPesewas < 0) throw new Error('Bad item');
    total += Math.round(i.qty * i.unitPesewas);
  }
  if (cash < 0 || momo < 0) throw new Error('Negative payment');
  if (momo > total) throw new Error('MoMo exceeds total');
  const cashApplied = Math.min(cash, total - momo);
  const change = cash - cashApplied;          // returned to customer, never revenue
  const credit = total - momo - cashApplied;  // owed by customer
  return { total, cashApplied, momo, change, credit, received: cashApplied + momo };
}

// sales: [{id, date, balance}] -> oldest first allocation; throws on overpayment
export function allocateRepayment(sales, amount) {
  const owed = sales.reduce((a, s) => a + s.balance, 0);
  if (!(amount > 0)) throw new Error('Amount must be positive');
  if (amount > owed) throw new Error('Repayment exceeds outstanding balance');
  let left = amount;
  return [...sales].sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id))
    .filter((s) => s.balance > 0)
    .map((s) => { const take = Math.min(left, s.balance); left -= take; return { id: s.id, take }; })
    .filter((x) => x.take > 0);
}
