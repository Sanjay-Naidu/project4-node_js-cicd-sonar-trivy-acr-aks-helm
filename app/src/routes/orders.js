'use strict';

const express = require('express');
const { z } = require('zod');
const store = require('../store/orderStore');
const { HttpError } = require('../middleware/errors');

const router = express.Router();

const ORDER_STATUSES = ['PENDING', 'PAID', 'SHIPPED', 'CANCELLED'];

const orderItemSchema = z.object({
  sku: z.string().min(1).max(64),
  quantity: z.number().int().positive().max(1000),
  // Minor units (cents) - integers only, so no floating point drift.
  unitPrice: z.number().int().nonnegative(),
});

const createOrderSchema = z.object({
  customer: z.string().min(1).max(200),
  // Default is applied first, then normalised - so an absent currency becomes
  // USD and a lowercase "usd" is stored canonically.
  currency: z
    .string()
    .length(3)
    .default('USD')
    .transform((value) => value.toUpperCase()),
  items: z.array(orderItemSchema).min(1).max(100),
});

const updateStatusSchema = z.object({
  status: z.enum(ORDER_STATUSES),
});

const listQuerySchema = z.object({
  status: z.enum(ORDER_STATUSES).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

/**
 * Express 4 does not forward rejected promises to the error handler, so async
 * handlers are wrapped rather than each one carrying its own try/catch.
 */
const asyncRoute = (handler) => (req, res, next) =>
  Promise.resolve(handler(req, res, next)).catch(next);

router.get(
  '/',
  asyncRoute((req, res) => {
    const query = listQuerySchema.parse(req.query);
    const { total, items } = store.list(query);
    res.status(200).json({
      total,
      limit: query.limit,
      offset: query.offset,
      items,
    });
  }),
);

router.post(
  '/',
  asyncRoute((req, res) => {
    const input = createOrderSchema.parse(req.body);
    const order = store.create(input);
    res.status(201).location(`${req.baseUrl}/${order.id}`).json(order);
  }),
);

router.get(
  '/:id',
  asyncRoute((req, res) => {
    const order = store.get(req.params.id);
    if (!order) {
      throw new HttpError(404, 'order_not_found', `Order ${req.params.id} does not exist`);
    }
    res.status(200).json(order);
  }),
);

router.patch(
  '/:id/status',
  asyncRoute((req, res) => {
    const { status } = updateStatusSchema.parse(req.body);
    const order = store.updateStatus(req.params.id, status);
    if (!order) {
      throw new HttpError(404, 'order_not_found', `Order ${req.params.id} does not exist`);
    }
    res.status(200).json(order);
  }),
);

router.delete(
  '/:id',
  asyncRoute((req, res) => {
    if (!store.remove(req.params.id)) {
      throw new HttpError(404, 'order_not_found', `Order ${req.params.id} does not exist`);
    }
    res.status(204).send();
  }),
);

module.exports = router;
