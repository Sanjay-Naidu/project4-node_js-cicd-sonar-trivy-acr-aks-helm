'use strict';

const request = require('supertest');
const { createApp } = require('../src/app');
const lifecycle = require('../src/lifecycle');

describe('probe endpoints', () => {
  let app;

  beforeEach(() => {
    lifecycle._reset();
    app = createApp();
  });

  describe('before the process has finished booting', () => {
    it('fails the startup probe', async () => {
      const res = await request(app).get('/healthz/startup');
      expect(res.status).toBe(503);
      expect(res.body.status).toBe('starting');
    });

    it('fails the readiness probe', async () => {
      const res = await request(app).get('/healthz/ready');
      expect(res.status).toBe(503);
      expect(res.body.status).toBe('not_ready');
    });

    it('still passes the liveness probe', async () => {
      // Liveness must not fail during boot, otherwise the kubelet would kill
      // the container before it ever had a chance to start.
      const res = await request(app).get('/healthz/live');
      expect(res.status).toBe(200);
    });
  });

  describe('once started', () => {
    beforeEach(() => lifecycle.markStarted());

    it.each([
      ['/healthz/startup', 'started'],
      ['/healthz/live', 'alive'],
      ['/healthz/ready', 'ready'],
    ])('%s returns 200', async (path, status) => {
      const res = await request(app).get(path);
      expect(res.status).toBe(200);
      expect(res.body.status).toBe(status);
    });

    it('marks probe responses as uncacheable', async () => {
      const res = await request(app).get('/healthz/ready');
      expect(res.headers['cache-control']).toBe('no-store');
    });

    it('reports build metadata on the info endpoint', async () => {
      const res = await request(app).get('/healthz');
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({
        service: 'orders-api',
        version: '1.0.0-test',
        gitSha: 'testsha',
        status: 'ready',
      });
    });
  });

  describe('during shutdown', () => {
    beforeEach(() => {
      lifecycle.markStarted();
      lifecycle.beginShutdown();
    });

    it('drains by failing readiness', async () => {
      const res = await request(app).get('/healthz/ready');
      expect(res.status).toBe(503);
      expect(res.body.status).toBe('draining');
    });

    it('keeps liveness passing so the pod is not restarted mid-drain', async () => {
      const res = await request(app).get('/healthz/live');
      expect(res.status).toBe(200);
    });

    it('keeps serving business traffic while draining', async () => {
      // The whole point of the drain window: connections already routed here
      // must still get a real answer.
      const res = await request(app).get('/api/v1/orders');
      expect(res.status).toBe(200);
    });
  });
});
