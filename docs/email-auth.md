# Email authentication

The iOS and macOS onboarding and Account settings offer native email/password
forms when Cloud advertises `email` in `/.well-known/codevisor`. No browser is
needed for signup, sign-in, verification, or password reset.

## Configuration

Verify `auth.codevisor.dev` in Resend and create a sending-only API key scoped to
that domain. Store it in the Worker secret `RESEND_API_KEY`. The sender defaults
to `Codevisor <noreply@auth.codevisor.dev>`; self-hosters can set `AUTH_EMAIL_FROM`.
Never put the key in native app configuration or checked-in files.

Apply the D1 migrations before deploying Cloud. They add persistent auth rate
limits and enforce one verification record per identifier. The migration retains
the newest record if duplicate challenges already exist.

For local testing, put the key in the ignored `apps/cloud/.env.local`. Ordinary
tests mock Resend and never send email. The development account remains separate
and does not require email delivery.

## Behavior

- New email accounts require a six-digit verification code before first use.
- Codes expire after ten minutes, are stored hashed, and can only be used once.
  Resending replaces the previous code. Five wrong attempts invalidate a code.
- Verified accounts sign in with their password; there is no email challenge on
  each login. An unfinished signup can resume verification from sign-in.
- Password reset uses a separate email code and revokes existing login sessions.
  The user then signs in with the new password. Machine API keys are separate.
- Apple and GitHub retain explicit account linking. Matching email addresses do
  not silently merge accounts. Resetting the password for an existing social
  account proves email ownership and adds password access to that same account.
- Delivery failures show a retryable error. Passwords and codes are never logged
  or stored in native preferences; only the resulting session enters Keychain.

Use an ordinary verified email account and a dedicated machine for App Review.
No reviewer account or special authentication bypass is provisioned by this change.
