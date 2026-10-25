import type { ErrorRequestHandler } from "express";
import { ZodError } from "zod";

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public code = "VALIDATION_ERROR",
  ) {
    super(message);
  }
}
export function requireCondition(
  condition: unknown,
  message: string,
  status = 422,
): asserts condition {
  if (!condition) throw new ApiError(status, message);
}
export const errorHandler: ErrorRequestHandler = (error, req, res, _next) => {
  let status = 500,
    code = "INTERNAL_ERROR",
    message = "The request could not be completed.";
  if (error instanceof ApiError) {
    ({ status, code, message } = error);
  } else if (error instanceof ZodError) {
    status = 422;
    code = "VALIDATION_ERROR";
    message = error.issues
      .map((i) => `${i.path.join(".") || "Request"}: ${i.message}`)
      .join("; ");
  } else if (["23505", "23P01", "23503", "23514"].includes(error.code)) {
    status = 409;
    code = "CONFLICT";
    message =
      error.code === "23P01"
        ? "This unit already has a lease within those dates."
        : error.code === "23505"
          ? "A record with these unique details already exists."
          : "The change conflicts with related records or a database rule.";
  } else if (error.type === "entity.parse.failed") {
    status = 400;
    code = "INVALID_JSON";
    message = "Send a valid JSON request body.";
  } else if (error.type === "entity.too.large") {
    status = 413;
    code = "BODY_TOO_LARGE";
    message = "The request body is too large.";
  }
  if (status >= 500)
    console.error(
      JSON.stringify({
        requestId: res.locals.requestId,
        method: req.method,
        path: req.path,
        code: error.code ?? "ERROR",
      }),
    );
  res
    .status(status)
    .json({ error: { code, message, requestId: res.locals.requestId } });
};
