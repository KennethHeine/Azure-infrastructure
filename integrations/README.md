# KS Integrations delegated access

`entra.bicep` owns the existing KS Integrations API and ChatGPT OAuth client.
Deploy it through **Configure KS Integrations Entra**, scoped to
`rg-ks-integrations`, using the exact existing connection callback. The app,
service-principal identities, v2 audience and read-scope identifier are retained.

| Delegated scope | Purpose |
| --- | --- |
| `integrations.read` | Read evidence and prepare private proposals. |
| `integrations.accounting` | Call the separately enabled, approval-bound draft and posting actions in KS Integrations. |
| `integrations.time.write` | Create the signed-in user's own time entries through the separately enabled create-only pilot. Does not edit, delete or invoice. |

Declaring the accounting scope and listing it in the OAuth client's required
resource access does not grant consent, expand existing access tokens, enable
writers or approve a voucher. It grants no Microsoft Graph application role or
Azure RBAC role. The existing read-only connection continues to request the read
scope unless the operator explicitly changes its requested permissions.

Before activating the accounting pilot:

1. Review the exact permission change and the deployed KS Integrations accounting
   implementation. Verify that the existing callback is still the intended one;
   this workflow declares a single callback and must not overwrite a client with
   additional callbacks that need to be retained.
2. Obtain authorization for the additional delegated permission and deploy this
   template through the existing manual workflow. Verify that the API/client IDs,
   read scope and callback are unchanged and the new accounting scope is present.
3. Enable writers only through the KS Integrations Bicep/Actions deployment and
   obtain consent for the qualified accounting scope in the intended connection.
   Verify that a read-only token is still refused by write tools.
4. Refresh source evidence and inspect the actual drafts. Obtain the exact
   method/create-or-update approval, verify the saved draft, then obtain the
   separate posting approval and verify the ledger result.

The initial production rule supports only the bounded bank-fee pilot. This scope
does not implement deletion, Rejsekort rules, standing automatic approvals,
payments, bank synchronization or reconciliation. Those features need their own
reviewed implementation. See the [accounting rollout contract](https://github.com/KennethHeine/ks-integrations/blob/main/docs/accounting-tools.md).

To pause execution, disable the KS Integrations writer flag first. Removing a
permission declaration alone does not revoke existing tokens or consent grants.

## Create-only time pilot

The time scope is an additive declaration on the existing API and OAuth client.
Its identifier remains deterministic:
`guid(tenant().tenantId, 'ks-integrations', 'integrations.time.write')`.
The existing read/accounting scope declarations and IDs, callbacks, applications,
service principals and consent grants are not part of this permission change.
Declaring a scope and required resource access does not grant OAuth consent,
change existing tokens or enable the application's writer. It adds no Graph
application permission, app role, credential or Azure role assignment.

Before an operator dispatches **Configure KS Integrations Entra** for this pilot,
fresh read-only Graph readback is required; source declarations alone do not prove
that the replacement arrays match live state:

1. Confirm tenant `14bc2ff7-5fd1-4ce2-a110-4f71b9a2ce41`, subscription and
   `rg-ks-integrations` match the existing deployment. Resolve the template's
   subscription/resource-group-derived `uniqueName` values to the existing API
   appId `0b6660c1-b844-48a8-aa0b-247843095112` and client appId
   `3ccec9f8-3565-48b2-9100-9c1a049801f7`. Stop if either identity differs or
   cannot be resolved; never create replacement applications.
2. Compare the API's complete `api.oauth2PermissionScopes`, v2 token setting and
   `identifierUris`, and the client's complete `requiredResourceAccess`,
   `publicClient.redirectUris`, audience and public-client setting against this
   template and the exact connection callback. Existing scope objects and access
   entries must match, with only the new time scope/access entry absent or
   already identical. Stop for unknown scopes, additional resources/callbacks or
   other drift; preserve them in a separately reviewed source change rather than
   guessing arrays or overwriting live values. Confirm the bound resource is
   `https://ca-ks-integrations.agreeabledune-ba4b906d.swedencentral.azurecontainerapps.io/mcp`.
3. Record the current delegated-consent readback for the intended existing
   connection. Obtain the separately coordinated deployment approval and use the
   existing manual lane, which now runs only the bound-identifier pass for this
   already-v2 API. The PR validation job only compiles Bicep and has no Azure
   login. After apply, read back the same objects and verify that the only
   additions are the time scope and its delegated client-access entry; the
   identities, callbacks, existing scopes/access and consent grants must match
   the preflight.
4. Once deployment is coordinated, use the supported user OAuth-consent flow on
   the existing connection to request
   `https://ca-ks-integrations.agreeabledune-ba4b906d.swedencentral.azurecontainerapps.io/mcp/integrations.time.write`.
   Do not fabricate tokens or grant admin consent on another user's behalf.

The create-only application implementation and journal managed identity/role
belong to `KennethHeine/ks-integrations` PR #30 and are not duplicated here.
Editing, deleting, invoicing, sharing links and accounting writes are outside
this time pilot. Pausing its application writer is the first containment step;
removing this declaration does not revoke issued tokens or existing consent.
