# Security Policy

> Last updated: May 9, 2026 - 7:00pm - GPT-5.3-Codex

## Supported Versions

Fixer is currently in active development. Security fixes are applied to the `main` branch first.

## Dependency License Policy

Fixer allows only dependency licenses compatible with commercial distribution.

Allowed by default:

- MIT
- BSD-2-Clause / BSD-3-Clause
- Apache-2.0
- ISC
- MPL-2.0

Prohibited in shipped application/server code unless explicitly approved by legal:

- GPL-2.0 / GPL-3.0
- AGPL-3.0
- LGPL (all versions)

Review requirements:

- Every new dependency must be reviewed in PR before merge.
- Any exception requires written legal approval and a documented rationale.

## Reporting a Vulnerability

Please report suspected vulnerabilities privately:

- Email: security@ms-fixer.com
- Subject: `[Security] <short summary>`

Please include:

- Affected endpoint, route, or component
- Reproduction steps
- Expected vs actual behavior
- Potential impact
- Any proof-of-concept details

## Response Expectations

- Initial acknowledgment: within 2 business days
- Triage and severity assessment: within 5 business days
- Remediation target:
  - Critical: as soon as possible
  - High: next scheduled patch window
  - Medium/Low: prioritized with regular releases

## Disclosure Guidance

Please do not publicly disclose vulnerabilities until a fix is available and confirmed in production.

## Safe Harbor

Good-faith security research conducted under this policy will not be pursued legally, provided there is no data exfiltration, service disruption, or privacy abuse.
