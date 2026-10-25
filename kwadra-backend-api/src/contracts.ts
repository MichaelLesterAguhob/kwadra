import { z } from "zod";
import { requireCondition } from "./errors.js";

const text = (max = 160) => z.string().trim().min(1).max(max);
const cents = z.number().int().safe().min(0).max(99_999_999_999_999);
const money = cents.min(1);
const revision = z.number().int().nonnegative().default(0);
export const propertyInput = z
  .object({
    id: z.uuid(),
    name: text(),
    address: text(500),
    type: text(60),
    image: z.enum(["residence", "apartment", "studio"]),
    notes: z.string().max(5000).default(""),
    details: z
      .object({
        contact: z.string().max(300).default(""),
        houseRules: z.string().max(5000).default(""),
        amenities: z.array(z.string().max(80)).max(30).default([]),
      })
      .strict()
      .default({ contact: "", houseRules: "", amenities: [] }),
    archived: z.boolean().default(false),
    revision,
  })
  .strict();
export const unitInput = z
  .object({
    id: z.uuid(),
    propertyId: z.uuid(),
    code: text(40),
    type: text(60),
    rent: money,
    capacity: z.number().int().min(1).max(20),
    floor: text(80),
    maintenance: z.boolean().default(false),
    notes: z.string().max(3000).default(""),
    revision,
  })
  .strict();
export const tenantInput = z
  .object({
    id: z.uuid(),
    name: text(),
    email: z.union([z.literal(""), z.email().max(254)]),
    phone: z.string().trim().max(60),
    emergency: z.string().max(1000).default(""),
    archived: z.boolean().default(false),
    revision,
  })
  .strict();
export const date = z.iso
  .date()
  .refine(
    (v) => v >= "1900-01-01" && v <= "2200-12-31",
    "Date must be between 1900 and 2200.",
  );
export const leaseInput = z
  .object({
    id: z.uuid(),
    unitId: z.uuid(),
    tenantIds: z.array(z.uuid()).min(1).max(20),
    start: date,
    end: date,
    rent: money,
    deposit: cents.default(0),
    dueDay: z.number().int().min(1).max(31),
    status: z.enum(["draft", "active"]).default("active"),
  })
  .strict();
export const ticketInput = z
  .object({
    id: z.uuid(),
    unitId: z.uuid(),
    title: text(),
    description: z.string().max(10000),
    category: z.enum([
      "Plumbing",
      "Electrical",
      "Appliance",
      "Structural",
      "General",
      "Other",
    ]),
    priority: z.enum(["Low", "Normal", "Urgent"]),
    status: z.enum(["Open", "In progress", "Resolved"]).default("Open"),
    revision,
  })
  .strict();
export const profileInput = z
  .object({
    name: text(120),
    email: z.email().max(254),
    organization: text(),
    revision: z.number().int().positive(),
  })
  .strict();
export const periodInput = z
  .object({ period: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/) })
  .strict();

export function decimal(cents: number) {
  return `${Math.trunc(cents / 100)}.${String(cents % 100).padStart(2, "0")}`;
}
export function centavos(value: string) {
  const [whole, fraction = ""] = value.split(".");
  const result = Number(BigInt(whole) * 100n + BigInt(fraction.padEnd(2, "0")));
  requireCondition(
    Number.isSafeInteger(result),
    "Amount exceeds supported precision.",
  );
  return result;
}
export const manilaToday = () =>
  new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
export function dueDate(period: string, day: number) {
  const [year, month] = period.split("-").map(Number);
  const last = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return `${period}-${String(Math.min(day, last)).padStart(2, "0")}`;
}
