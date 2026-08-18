'use strict';

const request = require('supertest');
const { createApp } = require('../src/app');
const store = require('../src/store/orderStore');
const lifecycle = require('../src/lifecycle');

const validOrder = {
  customer: 'Acme Corp',
  currency: 'usd',
  items: [
    { sku: 'WIDGET-1', quantity: 2, unitPrice: 1999 },
    { sku: 'GIZMO-7', quantity: 1, unitPrice: 4500 },
  ],
};

describe('orders API', () => {
  let app;

  beforeEach(() => {
    store.clear();
    lifecycle._reset();
    lifecycle.markStarted();
    app = createApp();
  });

  const createOrder = (overrides = {}) =>
    request(app)
      .post('/api/v1/orders')
      .send({ ...validOrder, ...overrides });

  describe('POST /api/v1/orders', () => {
    it('creates an order and returns 201 with a Location header', async () => {
      const res = await createOrder();

      expect(res.status).toBe(201);
      expect(res.body).toMatchObject({
        customer: 'Acme Corp',
        currency: 'USD',
        status: 'PENDING',
      });
      expect(res.body.id).toEqual(expect.any(String));
      expect(res.headers.location).toBe(`/api/v1/orders/${res.body.id}`);
    });

    it('computes the total in minor units', async () => {
      const res = await createOrder();
      // 2 * 1999 + 1 * 4500
      expect(res.body.totalMinorUnits).toBe(8498);
    });

    it('defaults the currency when omitted', async () => {
      const res = await createOrder({ currency: undefined });
      expect(res.body.currency).toBe('USD');
    });

    it.each([
      ['missing customer', { customer: undefined }],
      ['empty item list', { items: [] }],
      ['zero quantity', { items: [{ sku: 'A', quantity: 0, unitPrice: 100 }] }],
      ['fractional price', { items: [{ sku: 'A', quantity: 1, unitPrice: 10.5 }] }],
      ['negative price', { items: [{ sku: 'A', quantity: 1, unitPrice: -1 }] }],
      ['bad currency length', { currency: 'DOLLAR' }],
    ])('rejects %s with 400', async (_label, overrides) => {
      const res = await createOrder(overrides);

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('validation_failed');
      expect(res.body.error.details.length).toBeGreaterThan(0);
    });

    it('rejects malformed JSON with 400', async () => {
      const res = await request(app)
        .post('/api/v1/orders')
        .set('Content-Type', 'application/json')
        .send('{"customer": ');

      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('malformed_json');
    });
  });

  describe('GET /api/v1/orders', () => {
    it('returns an empty page when nothing exists', async () => {
      const res = await request(app).get('/api/v1/orders');
      expect(res.status).toBe(200);
      expect(res.body).toEqual({ total: 0, limit: 50, offset: 0, items: [] });
    });

    it('filters by status', async () => {
      const { body: first } = await createOrder();
      await createOrder();
      await request(app).patch(`/api/v1/orders/${first.id}/status`).send({ status: 'PAID' });

      const res = await request(app).get('/api/v1/orders').query({ status: 'PAID' });

      expect(res.status).toBe(200);
      expect(res.body.total).toBe(1);
      expect(res.body.items[0].id).toBe(first.id);
    });

    it('paginates', async () => {
      await createOrder();
      await createOrder();
      await createOrder();

      const res = await request(app).get('/api/v1/orders').query({ limit: 2, offset: 1 });

      expect(res.body.total).toBe(3);
      expect(res.body.items).toHaveLength(2);
    });

    it('rejects an out-of-range limit', async () => {
      const res = await request(app).get('/api/v1/orders').query({ limit: 5000 });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe('validation_failed');
    });
  });

  describe('GET /api/v1/orders/:id', () => {
    it('returns the order', async () => {
      const { body: created } = await createOrder();
      const res = await request(app).get(`/api/v1/orders/${created.id}`);

      expect(res.status).toBe(200);
      expect(res.body.id).toBe(created.id);
    });

    it('returns 404 for an unknown id', async () => {
      const res = await request(app).get('/api/v1/orders/does-not-exist');

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('order_not_found');
      expect(res.body.requestId).toEqual(expect.any(String));
    });
  });

  describe('PATCH /api/v1/orders/:id/status', () => {
    it('transitions the status and bumps updatedAt', async () => {
      const { body: created } = await createOrder();

      const res = await request(app)
        .patch(`/api/v1/orders/${created.id}/status`)
        .send({ status: 'SHIPPED' });

      expect(res.status).toBe(200);
      expect(res.body.status).toBe('SHIPPED');
      expect(res.body.createdAt).toBe(created.createdAt);
    });

    it('rejects an unknown status', async () => {
      const { body: created } = await createOrder();

      const res = await request(app)
        .patch(`/api/v1/orders/${created.id}/status`)
        .send({ status: 'TELEPORTED' });

      expect(res.status).toBe(400);
    });

    it('returns 404 for an unknown id', async () => {
      const res = await request(app)
        .patch('/api/v1/orders/nope/status')
        .send({ status: 'PAID' });

      expect(res.status).toBe(404);
    });
  });

  describe('DELETE /api/v1/orders/:id', () => {
    it('deletes and returns 204', async () => {
      const { body: created } = await createOrder();

      const res = await request(app).delete(`/api/v1/orders/${created.id}`);
      expect(res.status).toBe(204);

      const followUp = await request(app).get(`/api/v1/orders/${created.id}`);
      expect(followUp.status).toBe(404);
    });

    it('returns 404 when deleting twice', async () => {
      const { body: created } = await createOrder();
      await request(app).delete(`/api/v1/orders/${created.id}`);

      const res = await request(app).delete(`/api/v1/orders/${created.id}`);
      expect(res.status).toBe(404);
    });
  });
});
