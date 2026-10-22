# KS Integrations delegated access

`entra.bicep` owns the existing KS Integrations API and ChatGPT OAuth client.
Deploy it through **Configure KS Integrations Entra**, scoped to
`rg-ks-integrations`, using the exact existing connection callback. The app,
service-principal identities, v2 audience and read-scope identifier are retained.

| Delegated scope | Purpose |
| --- | --- |
| `integrations.read` | Read evidence and prepare private proposals. |
| `integrations.accounting` | Call the separately enabled, approval-bound draft and posting actions in KS Integrations. |

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
