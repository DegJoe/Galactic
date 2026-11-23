import test from 'node:test';
import assert from 'node:assert/strict';
import { calcSale, allocateRepayment, toPesewas } from '../src/money.js';
const it = (q, c) => ({ qty: q, unitPesewas: toPesewas(c) });

test('float-safe conversion', () => assert.equal(toPesewas(0.1 + 0.2), 30));
test('cash overpayment: change is not revenue', () => {
  const r = calcSale({ items: [it(3, 2.5)], cash: 1000 });
  assert.deepEqual(r, { total: 750, cashApplied: 750, momo: 0, change: 250, credit: 0, received: 750 });
});
test('exact cash', () => assert.equal(calcSale({ items: [it(1, 10)], cash: 1000 }).change, 0));
test('MoMo only', () => {
  const r = calcSale({ items: [it(2, 5)], momo: 1000 });
  assert.equal(r.received, 1000); assert.equal(r.credit, 0); assert.equal(r.change, 0);
});
test('MoMo cannot exceed total', () => assert.throws(() => calcSale({ items: [it(1, 5)], momo: 600 })));
test('mixed cash + MoMo with cash overpay', () => {
  const r = calcSale({ items: [it(1, 20)], cash: 1500, momo: 1000 });
  assert.equal(r.cashApplied, 1000); assert.equal(r.change, 500); assert.equal(r.received, 2000);
});
test('partial payment leaves credit', () => {
  const r = calcSale({ items: [it(1, 20)], cash: 500 });
  assert.equal(r.credit, 1500); assert.equal(r.received, 500);
});
test('full credit', () => assert.equal(calcSale({ items: [it(4, 3)] }).credit, 1200));
test('fractional quantity rounds to pesewa', () => assert.equal(calcSale({ items: [it(1.5, 3.33)], cash: 500 }).total, 500));
test('rejects bad input', () => {
  assert.throws(() => calcSale({ items: [] }));
  assert.throws(() => calcSale({ items: [it(0, 5)] }));
  assert.throws(() => calcSale({ items: [it(1, 5)], cash: -1 }));
});
test('repayment goes to oldest sale first', () => {
  const s = [{ id: 'b', date: '2026-11-02', balance: 500 }, { id: 'a', date: '2026-11-01', balance: 300 }];
  assert.deepEqual(allocateRepayment(s, 600), [{ id: 'a', take: 300 }, { id: 'b', take: 300 }]);
});
test('repayment over balance rejected', () =>
  assert.throws(() => allocateRepayment([{ id: 'a', date: '2026-11-01', balance: 300 }], 301)));
