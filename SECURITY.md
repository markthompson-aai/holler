# Security

Holler reads the screens of your coding agents and can send them messages, so we take security reports seriously.

If you find a vulnerability, please report it privately through GitHub's **Report a vulnerability** button on this repository's **Security** tab, rather than in a public issue. Include what you found, how to reproduce it, and what an attacker could do with it.

Things we especially want to hear about:

- A way for text on an agent's screen to make Holler send a message, start, interrupt or close anything without your confirmation.
- A secret that reaches LLM Gateway without being redacted.
- A way around `HOLLER_WORKSPACES` or `HOLLER_EXCLUDE_PATHS`.
- Your AssemblyAI API key leaving the Keychain, or being sent anywhere but AssemblyAI.
