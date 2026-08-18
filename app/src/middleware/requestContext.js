'use strict';

const { randomUUID } = require('node:crypto');

const HEADER = 'x-request-id';

/**
 * Propagates a correlation id across the request.
 *
 * Trusts an inbound id when the ingress/edge already minted one, so a single
 * trace survives the hop through NGINX; otherwise generates one. Always echoed
 * back on the response so a caller can quote it in a bug report.
 */
function requestContext(req, res, next) {
  const inbound = req.get(HEADER);
  // Bound the accepted value: an unbounded header would end up in every log
  // line and in metrics labels.
  const id = inbound && inbound.length <= 200 ? inbound : randomUUID();

  req.id = id;
  res.setHeader(HEADER, id);
  next();
}

module.exports = { requestContext, HEADER };
