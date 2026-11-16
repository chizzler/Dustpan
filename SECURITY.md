# Security reporting

For a suspected vulnerability, use GitHub's **Security → Report a vulnerability** on this repository
when that option is available. If it is unavailable, open an issue requesting a private reporting channel
without including exploit details or private data. Do not post tokens, credentials or databases publicly.

Include the affected client and version, operating system, a minimal reproduction with synthetic data,
and the impact you observed. No response-time or long-term support commitment is currently offered.
Fixes target the latest preview; older previews do not receive separate maintenance branches.

Dustpan supports unencrypted personal OpenTodo accounts. HTTPS is required except for loopback development
servers. Tokens are stored in a local configuration file restricted to the current user. Anyone with access
to that account or its files can read tasks and the token; local task databases are not encrypted by Dustpan.

For data-loss incidents, stop affected clients before attempting recovery and read
[dev/RECOVERY.md](dev/RECOVERY.md). Preserve copies of the database and its WAL files before experimenting.
