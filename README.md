# SnappyMail for Nextcloud 33

A maintained DOAP compatibility layer for the upstream SnappyMail Nextcloud integration.

## Objective

Provide reliable one-click SnappyMail login from Nextcloud 33 using the authenticated user's Nextcloud email address and the password captured during LDAP-backed Nextcloud login.

## Safety model

- The production standalone SnappyMail installation at `/var/www/snappymail` remains untouched.
- Builds are generated from a pinned upstream SnappyMail revision plus reviewable patches.
- CI performs syntax, compatibility and packaging checks.
- Production deployment is manual, backed up first, smoke-tested, and rolled back automatically on failure.

## Repository model

The upstream application is not copied blindly into this repository. `scripts/build.sh` downloads the pinned upstream source, extracts the Nextcloud integration, applies the patches in `patches/`, and produces an installable archive.

## Current status

Initial automation and Nextcloud 33 compatibility work are in progress. Do not deploy this repository to production until the NC33 test workflow and Dolphin end-to-end login tests pass.
