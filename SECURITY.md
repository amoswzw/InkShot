# Security policy

## Supported versions

Only the latest release is supported; fixes ship as a new release.

## Scope

Inkshot's promise is that **nothing leaves your Mac**: it contains no networking code, and CI
fails if any appears. It captures the screen with ScreenCaptureKit only when you ask, and the
Mac App Store build runs in the App Sandbox.

Reports about captures, history or recordings being exposed beyond the folders you chose are
especially welcome.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately instead:
on GitHub, open the **Security** tab of this repository and choose **Report a vulnerability**.

Please include as much as you can:

- the affected version or commit
- your macOS version and Mac model
- steps to reproduce, or a proof of concept
- what an attacker could do with it
- any ideas for a fix

## Response

- New reports are acknowledged within 72 hours.
- A first assessment follows within 7 days.
- Once a fix is out, we agree on a disclosure timeline with the reporter.
