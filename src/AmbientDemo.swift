import Foundation

// MARK: - ambient: the demo
//
// The fifty synthetic events the prototype was tuned with. `pager ambient
// --demo` plays them once and stops; the menu's Demo burst plays the next six.
// Never written to history.

enum AmbientDemo {
    static func events() -> [AmbientEvent] {
        struct Sample: Decodable { let source, kind, subject, text, detail: String }
        guard let samples = try? JSONDecoder().decode([Sample].self, from: Data(json.utf8)) else { return [] }
        return samples.enumerated().map { index, sample in
            var event = AmbientEvent(id: "demo_\(index)", source: AmbientConnection.slug(sample.source), text: sample.text)
            event.sourceName = sample.source
            event.type = sample.kind
            event.subject = sample.subject
            event.detail = sample.detail
            event.origin = "demo"
            switch sample.kind {
            case "failure", "error", "down": event.severity = "error"
            case "warning": event.severity = "warn"
            default: event.severity = "info"
            }
            return event
        }
    }

    static let json = #"""
[
  {"source": "GitHub", "kind": "push", "subject": "billing-api", "text": "Maya pushed **3 commits** to `main`", "detail": "Handle prorated upgrades without rounding drift"},
  {"source": "Narkis", "kind": "sale", "subject": "New subscription", "text": "**$29 / month** · Creator plan", "detail": "A new creator joined Narkis"},
  {"source": "GitHub", "kind": "pr", "subject": "web-app #184", "text": "Jon opened **Improve keyboard navigation**", "detail": "12 files changed · ready for review"},
  {"source": "Coolify", "kind": "deploy", "subject": "billing-api · staging", "text": "Deployment **completed** in 38s", "detail": "`main@a3f921c` · health checks passing"},
  {"source": "Uptime", "kind": "down", "subject": "status.example.test", "text": "Site is **unreachable**", "detail": "HTTP 503 · checked from 3 regions"},
  {"source": "GitHub", "kind": "merge", "subject": "web-app #179", "text": "Leah merged **Fix checkout redirect**", "detail": "`fix/checkout` → `main`"},
  {"source": "Coolify", "kind": "failure", "subject": "web-app · production", "text": "Deployment **failed** · build error", "detail": "`npm run build` exited with code 1\nPrevious deployment is still serving traffic"},
  {"source": "GitHub", "kind": "push", "subject": "design-system", "text": "Leah pushed **1 commit** to `tokens`", "detail": "Tune neutral colors for dark mode"},
  {"source": "Narkis", "kind": "sale", "subject": "Annual subscription", "text": "**$249 / year** · Creator plan", "detail": "First annual subscription today"},
  {"source": "Uptime", "kind": "recovery", "subject": "status.example.test", "text": "Site is **back online**", "detail": "HTTP 200 · incident lasted 2m 14s"},
  {"source": "GitHub", "kind": "pr", "subject": "billing-api #92", "text": "Maya opened **Prorated plan changes**", "detail": "Includes migration notes and rollback steps"},
  {"source": "Production", "kind": "error", "subject": "checkout-worker", "text": "**14 payment retries** in the last minute", "detail": "`GatewayTimeout` · upstream response exceeded 10s"},
  {"source": "Coolify", "kind": "deploy", "subject": "web-app · production", "text": "Deployment **completed** in 52s", "detail": "`main@b6d013e` · checkout fix is live"},
  {"source": "GitHub", "kind": "push", "subject": "infra", "text": "Adam pushed **2 commits** to `main`", "detail": "Increase worker memory limits"},
  {"source": "Narkis", "kind": "activity", "subject": "Generation finished", "text": "A creator generated **24 portraits**", "detail": "Completed in 46s"},
  {"source": "GitHub", "kind": "merge", "subject": "design-system #41", "text": "Jon merged **Accessible focus rings**", "detail": "Published as `@studio/ui@2.8.0`"},
  {"source": "Backups", "kind": "success", "subject": "Production database", "text": "Nightly backup **completed**", "detail": "2.4 GB · encrypted · off-site copy verified"},
  {"source": "GitHub", "kind": "pr", "subject": "mobile-api #203", "text": "Sam opened **Cursor-based pagination**", "detail": "*Draft* · feedback welcome on the response format"},
  {"source": "Coolify", "kind": "deploy", "subject": "narkis · production", "text": "Deployment **completed** in 1m 12s", "detail": "Faster image previews are live"},
  {"source": "Narkis", "kind": "sale", "subject": "Credit purchase", "text": "**$15** · 100 extra credits", "detail": "Returning customer"},
  {"source": "GitHub", "kind": "push", "subject": "web-app", "text": "Jon pushed **5 commits** to `a11y/navigation`", "detail": "Keyboard shortcuts, focus management, and tests"},
  {"source": "Uptime", "kind": "warning", "subject": "api.example.test", "text": "Response time rose to **1.8s**", "detail": "Usually 180ms · Frankfurt region"},
  {"source": "GitHub", "kind": "merge", "subject": "billing-api #92", "text": "Adam merged **Prorated plan changes**", "detail": "Approved by Sam and Leah"},
  {"source": "CI", "kind": "failure", "subject": "mobile-api #203", "text": "**2 checks failed**", "detail": "`pagination.integration`\nExpected stable ordering across page boundaries"},
  {"source": "Narkis", "kind": "activity", "subject": "New signup", "text": "A new creator joined from **organic search**", "detail": "Exploring the portrait studio"},
  {"source": "GitHub", "kind": "push", "subject": "docs", "text": "Sam pushed **1 commit** to `main`", "detail": "Document the new pagination contract"},
  {"source": "Coolify", "kind": "deploy", "subject": "billing-api · production", "text": "Deployment **completed** in 44s", "detail": "Prorated plan changes are live"},
  {"source": "Production", "kind": "recovery", "subject": "checkout-worker", "text": "Payment retries **returned to normal**", "detail": "No gateway timeouts in the last 5 minutes"},
  {"source": "GitHub", "kind": "pr", "subject": "infra #67", "text": "Adam opened **Separate background workers**", "detail": "Moves CPU-heavy jobs off the API instances"},
  {"source": "Calendar", "kind": "activity", "subject": "Engineering", "text": "Architecture session starts in **15 minutes**", "detail": "Optional · event pipeline design"},
  {"source": "Narkis", "kind": "sale", "subject": "Plan upgrade", "text": "Creator → **Studio · $79 / month**", "detail": "An existing customer upgraded"},
  {"source": "GitHub", "kind": "push", "subject": "mobile-api", "text": "Sam pushed **2 commits** to `cursor-pagination`", "detail": "Fix ordering when multiple records share a timestamp"},
  {"source": "CI", "kind": "success", "subject": "mobile-api #203", "text": "**All checks passed**", "detail": "148 tests · 2m 08s"},
  {"source": "Coolify", "kind": "failure", "subject": "preview-pr-184", "text": "Preview deployment **failed**", "detail": "Image registry unavailable\nProduction is unaffected"},
  {"source": "GitHub", "kind": "merge", "subject": "web-app #184", "text": "Maya merged **Improve keyboard navigation**", "detail": "Keyboard-only checkout now supported"},
  {"source": "Uptime", "kind": "recovery", "subject": "api.example.test", "text": "Response time **back to 190ms**", "detail": "All monitored regions healthy"},
  {"source": "GitHub", "kind": "push", "subject": "narkis", "text": "Adam pushed **4 commits** to `gallery`", "detail": "Lazy-load thumbnails and preserve scroll position"},
  {"source": "Narkis", "kind": "sale", "subject": "New subscription", "text": "**$79 / month** · Studio plan", "detail": "A small team joined Narkis"},
  {"source": "Production", "kind": "error", "subject": "image-worker", "text": "**3 generation jobs failed**", "detail": "`OutOfMemoryError`\nJobs returned to the queue for retry"},
  {"source": "GitHub", "kind": "pr", "subject": "narkis #58", "text": "Adam opened **A faster portrait gallery**", "detail": "*Draft* · includes before-and-after recordings"},
  {"source": "Coolify", "kind": "deploy", "subject": "docs · production", "text": "Deployment **completed** in 16s", "detail": "Pagination guide published"},
  {"source": "GitHub", "kind": "merge", "subject": "infra #67", "text": "Sam merged **Separate background workers**", "detail": "Worker pool rollout can begin"},
  {"source": "Backups", "kind": "warning", "subject": "Asset archive", "text": "Backup is **taking longer than usual**", "detail": "Running for 18m · previous average 6m"},
  {"source": "Narkis", "kind": "activity", "subject": "Daily milestone", "text": "Creators made **1,000 portraits** today", "detail": "Across 83 generation sessions"},
  {"source": "GitHub", "kind": "push", "subject": "billing-api", "text": "Maya pushed **1 commit** to `main`", "detail": "Clarify invoice line descriptions"},
  {"source": "Coolify", "kind": "deploy", "subject": "image-worker · production", "text": "New worker pool **is healthy**", "detail": "3 instances · 4 GB memory each"},
  {"source": "Production", "kind": "recovery", "subject": "image-worker", "text": "Generation queue **caught up**", "detail": "0 waiting · error rate back to baseline"},
  {"source": "GitHub", "kind": "merge", "subject": "mobile-api #203", "text": "Leah merged **Cursor-based pagination**", "detail": "Backward-compatible API update"},
  {"source": "Narkis", "kind": "sale", "subject": "Annual subscription", "text": "**$699 / year** · Studio plan", "detail": "A monthly customer switched to annual billing"},
  {"source": "Backups", "kind": "success", "subject": "Asset archive", "text": "Backup **completed**", "detail": "18.6 GB archived · checksum verification passed"}
]
"""#
}
