"""Helpers for the email optimization loop.

Model A: templates are immutable. Per-iteration content is passed as `variables`
to POST /api/emails/send; the campaign is just a grouping tag. No template cloning
or mutation. Sends are idempotent + resumable via the email_events ledger.

Uses curl via subprocess so we don't hit Python 3.13's local SSL cert issue.
"""
import json
import math
import os
import subprocess

API_KEY = os.environ["KALYGO_API_KEY"]
BASE = os.environ["KALYGO_API_BASE_URL"]


def _curl(method, path, body=None):
    cmd = [
        "curl", "-sS", "-X", method,
        "-H", f"X-API-Key: {API_KEY}",
        "-H", "Content-Type: application/json",
        f"{BASE}{path}",
    ]
    if body is not None:
        cmd += ["--data-binary", "@-"]
        proc = subprocess.run(
            cmd, input=json.dumps(body).encode(),
            capture_output=True, check=False,
        )
    else:
        proc = subprocess.run(cmd, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"curl failed: {proc.stderr.decode()}")
    raw = proc.stdout
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise RuntimeError(f"non-JSON response from {method} {path}: {raw[:500]!r}")


def get_template(tid):
    """Fetch a template. Read-only — the loop never mutates templates anymore."""
    return _curl("GET", f"/api/email-templates/{tid}")


def create_campaign(name, contact_list_id=None, description=None):
    """Create a grouping-tag campaign. No template/content is stored on it."""
    body = {"name": name}
    if contact_list_id is not None:
        body["contact_list_id"] = contact_list_id
    if description is not None:
        body["description"] = description
    return _curl("POST", "/api/email-campaigns/", body)


def patch_campaign(cid, body):
    return _curl("PATCH", f"/api/email-campaigns/{cid}", body)


def send_email(campaign_id, template_id, variables, recipient,
               credential_id, dry_run=False):
    """The send primitive: render `template_id` with `variables` (+ contact
    personalization + backend tokens) and deliver to one recipient.

    recipient: {"contact_id": N} (preferred) or {"email": "..."}.
    Returns SendEmailResponse: {campaign_id, contact_id, tracking_id, status, event_id}
    where status is "sent" | "skipped_duplicate" | "validated" (dry_run).
    """
    return _curl("POST", "/api/emails/send", {
        "campaign_id": campaign_id,
        "template_id": template_id,
        "variables": variables or {},
        "recipient": recipient,
        "credential_id": credential_id,
        "dry_run": dry_run,
    })


def get_unsent(campaign_id, contact_list_id=None):
    """Contacts in the list that have no send event for this campaign yet.
    Returns {campaign_id, contact_list_id, remaining: [{contact_id, email, ...}]}.
    """
    path = f"/api/email-campaigns/{campaign_id}/unsent"
    if contact_list_id is not None:
        path += f"?contact_list_id={contact_list_id}"
    return _curl("GET", path)


def execute_campaign(campaign_id, template_id, variables, contact_list_id,
                     credential_id, dry_run=False):
    """Send `template_id` rendered with `variables` to every not-yet-sent contact
    in `contact_list_id`, under `campaign_id`.

    Idempotent + resumable: only the contacts returned by /unsent are attempted,
    and the backend dedupes (campaign_id, contact_id), so re-running after a crash
    sends only the remainder with no double-mailing. Returns a summary dict.
    """
    remaining = get_unsent(campaign_id, contact_list_id).get("remaining", [])
    summary = {"total_remaining": len(remaining), "sent": 0,
               "skipped_duplicate": 0, "failed": 0, "errors": []}
    for c in remaining:
        recipient = ({"contact_id": c["contact_id"]} if c.get("contact_id")
                     else {"email": c.get("email")})
        try:
            resp = send_email(campaign_id, template_id, variables, recipient,
                              credential_id, dry_run)
            status = resp.get("status", "")
            if status in ("sent", "validated"):
                summary["sent"] += 1
            elif status == "skipped_duplicate":
                summary["skipped_duplicate"] += 1
            else:
                summary["failed"] += 1
                summary["errors"].append({"recipient": recipient, "response": resp})
        except Exception as e:  # noqa: BLE001 - record and continue the batch
            summary["failed"] += 1
            summary["errors"].append({"recipient": recipient, "error": str(e)})
    return summary


def get_ratings_summary(cid):
    """Returns {campaign_id, total_ratings, average_rating, distribution, by_template}."""
    return _curl("GET", f"/api/email-campaigns/{cid}/ratings/summary")


def balanced_score(avg_rating, num_ratings, send_count):
    if send_count == 0:
        return 0.0
    return float(avg_rating) * math.sqrt(num_ratings / send_count)