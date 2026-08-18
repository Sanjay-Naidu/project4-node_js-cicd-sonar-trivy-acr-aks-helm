'use strict';

const request = require('supertest');
const { createApp } = require('../src/app');
const store = require('../src/store/orderStore');
const lifecycle = require('../src/lifecycle');
const { HEADER } = require('../src/middleware/requestContext');

describe('application cross-cutting concerns', () => {
  let app;

  beforeEach(() => {
    store.clear();
    lifecycle._reset();
    lifecycle.markStarted();
    app = createApp();
  });

  describe('service root', () => {
    it('advertises build metadata and routes', async () => {
      const res = await request(app).get('/');

      expect(res.status).toBe(200);
      expect(res.body.service).toBe('orders-api');
      expect(res.body.endpoints).toContain('/api/v1/orders');
    });
  });

  describe('request correlation', () => {
    it('generates a request id when none is supplied', async () => {
      const res = await request(app).get('/');
      expect(res.headers[HEADER]).toEqual(expect.any(String));
      expect(res.headers[HEADER].length).toBeGreaterThan(0);
    });

    it('honours an inbound request id from the edge', async () => {
      const res = await request(app).get('/').set(HEADER, 'trace-abc-123');
      expect(res.headers[HEADER]).toBe('trace-abc-123');
    });

    it('replaces an absurdly long inbound id', async () => {
      const res = await request(app).get('/').set(HEADER, 'x'.repeat(500));
      expect(res.headers[HEADER]).not.toBe('x'.repeat(500));
    });
  });

  describe('security headers', () => {
    it('applies helmet defaults', async () => {
      const res = await request(app).get('/');
      expect(res.headers['x-content-type-options']).toBe('nosniff');
      expect(res.headers['strict-transport-security']).toBeDefined();
    });

    it('does not advertise the framework', async () => {
      const res = await request(app).get('/');
      expect(res.headers['x-powered-by']).toBeUndefined();
    });
  });

  describe('metrics endpoint', () => {
    it('exposes the Prometheus exposition format', async () => {
      const res = await request(app).get('/metrics');

      expect(res.status).toBe(200);
      expect(res.headers['content-type']).toMatch(/text\/plain/);
      expect(res.text).toContain('process_cpu_user_seconds_total');
    });

    it('records request metrics against the matched route, not the raw URL', async () => {
      const { body: created } = await request(app).post('/api/v1/orders').send({
        customer: 'Metrics Co',
        items: [{ sku: 'M-1', quantity: 1, unitPrice: 100 }],
      });
      await request(app).get(`/api/v1/orders/${created.id}`);

      const res = await request(app).get('/metrics');

      // The order id must be collapsed into the :id placeholder, otherwise
      // every request would create a new time series.
      expect(res.text).toContain('route="/api/v1/orders/:id"');
      expect(res.text).not.toContain(created.id);
    });

    it('tracks the current order count', async () => {
      await request(app)
        .post('/api/v1/orders')
        .send({ customer: 'A', items: [{ sku: 'S', quantity: 1, unitPrice: 1 }] });

      const res = await request(app).get('/metrics');
      expect(res.text).toMatch(/orders_current_total\{[^}]*\}\s1/);
    });
  });

  describe('error handling', () => {
    it('returns a structured 404 for unknown routes', async () => {
      const res = await request(app).get('/no/such/thing');

      expect(res.status).toBe(404);
      expect(res.body.error.code).toBe('not_found');
      expect(res.body.requestId).toEqual(expect.any(String));
    });

    it('rejects a body over the configured limit with 413', async () => {
      const res = await request(app)
        .post('/api/v1/orders')
        .send({ customer: 'x'.repeat(200_000), items: [] });

      expect(res.status).toBe(413);
      expect(res.body.error.code).toBe('payload_too_large');
    });
  });
});
