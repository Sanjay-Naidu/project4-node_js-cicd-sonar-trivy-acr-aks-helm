'use strict';

/**
 * In-memory order repository.
 *
 * Deliberately not a database: the point of this project is the delivery
 * pipeline, and a stateful backing store would add cost and moving parts
 * without changing the CI/CD story. The interface is written as a repository
 * so swapping in Cosmos DB / PostgreSQL is a single-file change.
 */

const { randomUUID } = require('node:crypto');
const { ordersTotal } = require('../metrics');

/** @type {Map<string, object>} */
const orders = new Map();

function syncGauge() {
  ordersTotal.set(orders.size);
}

function list({ status, limit = 50, offset = 0 } = {}) {
  let items = Array.from(orders.values());
  if (status) {
    items = items.filter((order) => order.status === status);
  }
  // Newest first - stable and what a UI would want by default.
  items.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  return { total: items.length, items: items.slice(offset, offset + limit) };
}

function get(id) {
  return orders.get(id) ?? null;
}

function create(input) {
  const now = new Date().toISOString();
  const total = input.items.reduce((sum, item) => sum + item.unitPrice * item.quantity, 0);

  const order = {
    id: randomUUID(),
    customer: input.customer,
    items: input.items,
    // Money as integer minor units; floats and currency do not mix.
    totalMinorUnits: Math.round(total),
    currency: input.currency,
    status: 'PENDING',
    createdAt: now,
    updatedAt: now,
  };

  orders.set(order.id, order);
  syncGauge();
  return order;
}

function updateStatus(id, status) {
  const existing = orders.get(id);
  if (!existing) {
    return null;
  }
  const updated = { ...existing, status, updatedAt: new Date().toISOString() };
  orders.set(id, updated);
  return updated;
}

function remove(id) {
  const deleted = orders.delete(id);
  syncGauge();
  return deleted;
}

function clear() {
  orders.clear();
  syncGauge();
}

module.exports = { list, get, create, updateStatus, remove, clear };
