import { backfillSubscriptionsFromStripe } from "../../services/billing/backfillFromStripe";

// Rebuild stripe_customers, stripe_subscriptions, and Stack Pro metadata from
// Stripe. Dry-run by default; `--apply` writes.
//
//   bun scripts/stripe/backfill-subscriptions-from-stripe.ts            # report only
//   bun scripts/stripe/backfill-subscriptions-from-stripe.ts --apply    # write
//
// Needs STRIPE_SECRET_KEY, the Stack server keys, and DATABASE_URL (or the
// aws-rds-iam variables) for the target database.
const args = process.argv.slice(2);
const apply = args.includes("--apply");
const unknown = args.filter((argument) => argument !== "--apply");
if (unknown.length > 0) {
  throw new Error(`Unknown argument: ${unknown[0]}`);
}

const result = await backfillSubscriptionsFromStripe({
  apply_mode: apply ? "apply" : "dry-run",
  log: (line) => console.log(line),
});
console.log(JSON.stringify({ mode: apply ? "apply" : "dry-run", ...result }, null, 2));
if (result.failed > 0) process.exit(1);
