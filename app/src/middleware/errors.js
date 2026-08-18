'use strict';

const { ZodError } = require('zod');
const logger = require('../logger');
const config = require('../config');

/** Error carrying an intended HTTP status, thrown by route/domain code. */
class HttpError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

function notFoundHandler(req, res, next) {
  next(new HttpError(404, 'not_found', `No route for ${req.method} ${req.path}`));
}

/**
 * Terminal error handler. Produces a stable RFC7807-ish JSON shape and never
 * leaks internals: 5xx bodies carry a generic message plus the request id, and
 * the stack goes to the log where it belongs.
 */
// eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity.
function errorHandler(err, req, res, next) {
  let status = err.status || 500;
  let code = err.code || 'internal_error';
  let message = err.message;
  let details;

  if (err instanceof ZodError) {
    status = 400;
    code = 'validation_failed';
    message = 'Request body failed validation';
    details = err.issues.map((issue) => ({
      field: issue.path.join('.') || '(root)',
      message: issue.message,
    }));
  } else if (err instanceof HttpError) {
    details = err.details;
  } else if (err.type === 'entity.parse.failed') {
    status = 400;
    code = 'malformed_json';
    message = 'Request body is not valid JSON';
  } else if (err.type === 'entity.too.large') {
    status = 413;
    code = 'payload_too_large';
    message = 'Request body exceeds the configured limit';
  }

  const log = status >= 500 ? logger.error.bind(logger) : logger.warn.bind(logger);
  log(
    {
      requestId: req.id,
      method: req.method,
      path: req.path,
      status,
      code,
      err: { message: err.message, stack: err.stack },
    },
    'request failed',
  );

  if (status >= 500 && config.isProduction) {
    message = 'An unexpected error occurred';
    details = undefined;
  }

  res.status(status).json({
    error: { code, message, ...(details ? { details } : {}) },
    requestId: req.id,
  });
}

module.exports = { HttpError, notFoundHandler, errorHandler };
