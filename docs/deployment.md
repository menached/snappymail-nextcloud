# Deployment plan

Production deployment is intentionally not enabled yet.

## Preconditions

- CI package build passes.
- Nextcloud 33 disposable-instance test passes.
- The `NextcloudPlugin` runtime loading error is resolved.
- Fresh-login auto-login succeeds for `dolphin@devopsandplatforms.com`.
- Send, receive, logout and session-isolation tests pass.

## Production safeguards

A future manually triggered deployment workflow must:

1. Verify it is running against `cloud.doap.com`.
2. Confirm the native `snappymail` app is disabled before replacement.
3. Back up the existing app directory under `/mnt/data/backups`.
4. Preserve the standalone `/var/www/snappymail` installation and its data.
5. Install the candidate into a temporary directory and validate ownership and PHP syntax.
6. Atomically replace only the Nextcloud app directory.
7. Enable the app and run authenticated smoke tests.
8. Inspect the Nextcloud log for new SnappyMail exceptions.
9. Disable and restore the previous app automatically if validation fails.

## Required GitHub configuration

Before production deployment automation is added, create a protected GitHub environment named `production` and configure repository or environment secrets for the restricted deployment account. The deployment key must not provide unrestricted root access.
