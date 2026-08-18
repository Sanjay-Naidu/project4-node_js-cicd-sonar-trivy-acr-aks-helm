'use strict';

/**
 * Pod lifecycle state machine, shared between the health routes and the
 * shutdown handler in index.js.
 *
 * The three Kubernetes probes map onto distinct questions, and conflating them
 * is the single most common cause of flapping rollouts:
 *
 *   startup   -> "has the process finished booting?"  (gates the other two)
 *   readiness -> "should traffic be routed here now?" (flips false on SIGTERM)
 *   liveness  -> "is the process irrecoverably stuck?" (must NOT fail on load,
 *                dependency outages, or during drain - that would restart a
 *                perfectly healthy pod and turn a blip into an outage)
 */

const state = {
  started: false,
  ready: false,
  shuttingDown: false,
  startedAt: null,
};

module.exports = {
  markStarted() {
    state.started = true;
    state.ready = true;
    state.startedAt = Date.now();
  },

  /**
   * Called on SIGTERM. Readiness immediately reports false so endpoints are
   * withdrawn, while the server keeps serving in-flight and newly-arriving
   * requests until the drain window elapses.
   */
  beginShutdown() {
    state.shuttingDown = true;
    state.ready = false;
  },

  isStarted: () => state.started,
  isReady: () => state.ready && !state.shuttingDown,
  isShuttingDown: () => state.shuttingDown,

  /** Liveness stays true for the whole lifetime, including drain. */
  isLive: () => true,

  uptimeSeconds: () =>
    state.startedAt === null ? 0 : Math.floor((Date.now() - state.startedAt) / 1000),

  /** Test-only hook so each suite starts from a clean slate. */
  _reset() {
    state.started = false;
    state.ready = false;
    state.shuttingDown = false;
    state.startedAt = null;
  },
};
