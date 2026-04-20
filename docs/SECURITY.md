# Security Policy

We take the security of Osaurus seriously. If you believe you have found a security vulnerability, please follow the process below.

## Supported versions

- `main` (development) — actively maintained
- The latest tagged release — actively maintained

Older releases may not receive security updates.

## Reporting a vulnerability

Please do not disclose security issues publicly. Instead, use one of the following private channels:

1. Open a private report via GitHub Security Advisories for this repository
2. If you prefer email, contact the maintainers privately (do not use a public issue)

What to include in your report:

- A clear description of the issue and impact
- Steps to reproduce, including sample input and configuration
- Any known mitigations

We will acknowledge receipt within 72 hours, assess the impact, and work on a fix. We may request additional information for reproduction.

## Current Security Focus

The chat-native agent loop introduced by the Work Mode migration makes folder access, sandbox execution, shared artifacts, and plugin dispatch the primary trust boundaries.

When changing those areas:

- keep host-folder paths relative to the selected working folder
- keep sandbox paths constrained to the sandbox workspace and artifact staging areas
- keep shared artifacts under the per-session artifact root before exposing them to plugins or HTTP clients
- treat plugin-dispatched tasks as headless chat sessions, not privileged Work Mode jobs

The active hardening plan is tracked in [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md), especially the artifact-security and agent-loop stabilization work.

## Disclosure

Once a fix is available, we will credit reporters who wish to be acknowledged and include mitigation instructions in the release notes when applicable.
