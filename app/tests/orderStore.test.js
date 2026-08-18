'use strict';

const store = require('../src/store/orderStore');

const input = (overrides = {}) => ({
  customer: 'Test Customer',
  currency: 'EUR',
  items: [{ sku: 'A-1', quantity: 3, unitPrice: 250 }],
  ...overrides,
});

describe('orderStore', () => {
  beforeEach(() => store.clear());

  it('assigns an id, timestamps and PENDING status on create', () => {
    const order = store.create(input());

    expect(order.id).toEqual(expect.any(String));
    expect(order.status).toBe('PENDING');
    expect(order.createdAt).toBe(order.updatedAt);
    expect(order.totalMinorUnits).toBe(750);
  });

  it('returns null for an unknown id', () => {
    expect(store.get('missing')).toBeNull();
  });

  it('sorts list results newest first', () => {
    jest.useFakeTimers().setSystemTime(new Date('2026-01-01T00:00:00.000Z'));
    const older = store.create(input());
    jest.setSystemTime(new Date('2026-01-02T00:00:00.000Z'));
    const newer = store.create(input());
    jest.useRealTimers();

    const { items } = store.list();
    expect(items.map((o) => o.id)).toEqual([newer.id, older.id]);
  });

  it('reports the unfiltered total alongside the page', () => {
    store.create(input());
    store.create(input());
    store.create(input());

    const { total, items } = store.list({ limit: 1, offset: 0 });

    expect(total).toBe(3);
    expect(items).toHaveLength(1);
  });

  it('does not mutate the stored order in place on status update', () => {
    const created = store.create(input());
    const updated = store.updateStatus(created.id, 'PAID');

    // `created` is the object the caller already holds; updating must not
    // retroactively change it.
    expect(created.status).toBe('PENDING');
    expect(updated.status).toBe('PAID');
  });

  it('returns null when updating an unknown id', () => {
    expect(store.updateStatus('missing', 'PAID')).toBeNull();
  });

  it('reports whether a delete removed anything', () => {
    const created = store.create(input());

    expect(store.remove(created.id)).toBe(true);
    expect(store.remove(created.id)).toBe(false);
  });
});
