import { startAnalytics } from "./analytics/client.js";

try {
  startAnalytics();
} catch {
  // Analytics must never break the page.
}
