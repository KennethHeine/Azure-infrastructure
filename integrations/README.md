# KS Integrations Entra source handoff

The API/OAuth declarations are maintained in
[`ks-integrations/infra/entra`](https://github.com/KennethHeine/ks-integrations/tree/main/infra/entra).
This directory retains the historical central template; do not deploy it.
The central **Configure KS Integrations Entra** workflow is retired and refuses
execution.

Use the app repository's
[`configure-entra.yml`](https://github.com/KennethHeine/ks-integrations/blob/main/.github/workflows/configure-entra.yml)
only after the [migration and one-writer gates](https://github.com/KennethHeine/ks-integrations/blob/main/docs/entra-migration.md)
have passed: verify the existing deploy identity's actual Graph permission and
application owners, retire/deactivate this central lane and finish any existing
runs, record the real retirement commit in the app contract, then review the
complete live bindings and arrays. Run the exact reviewed app main SHA with
`apply=false` before a separately coordinated application apply. Never use the
historical `bindIdentifier=false` pass; it would clear the existing identifier URI.

Preserve the existing applications and service principals, app/object IDs,
uniqueNames, credentials, callback, identifier URI, scopes and consent grants.
Moving source does not require a new identity, secret or OAuth connection.
Bootstrap remains shared platform work; this source retirement runs no onboarding
and grants no authority.

Accounting permission changes, connection consent and writer rollout follow the
app repository's current [Entra guidance](https://github.com/KennethHeine/ks-integrations/blob/main/docs/entra-login.md)
and [Dinero action contracts](https://github.com/KennethHeine/ks-integrations/blob/main/docs/dinero-actions.md).
The central accounting-pilot deployment procedure is retired. Removing a source
declaration does not revoke existing tokens or consent grants. PR #89's proposed
time-write scope remains a separate held change.
