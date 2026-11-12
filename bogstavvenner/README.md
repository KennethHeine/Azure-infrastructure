# Bogstavvenner deployment polling

The app is in `rg-bogstavvenner`; DNS is in `dns/records.app.json`.
The app's own Bicep binds `bog.kscloud.io`.

On 2026-11-12, ARM created the domain successfully (domain Ready, HTTPS verified)
but its custom-domain operation stayed Running/Forbidden. The exact error was
`AuthorizationFailed` for `Microsoft.Web/locations/staticSitesOperationStatuses/read`
at a subscription/location scope outside the app resource group. Evidence:
KennethHeine/bogstavvenner Actions run 43238631987; original ARM deployment
`infra-20261112142131`.

Azure rejected the exact action with `InvalidActionOrNotAction` in control-plane
run 43239082126: the SWA polling action is missing from its role-action catalogue.
Azure allows only one wildcard in an action pattern (run 43239407363), so the
supported pattern is `Microsoft.Web/locations/*/read`. It covers regional Web
metadata and operation status/results, including the missing SWA action.
It does not match application configuration, publishing credentials or data APIs.


`operation-status.bicep` grants only that regional metadata/status read category to the
verified existing deployment principal `sp-bogstavvenner-github`, object ID
`c17e4f05-e194-449d-afbd-fadbfa06009e`. It grants no application resource inventory reads,
resource writes, data access or rights to other identities. The dedicated
workflow verifies the tenant, subscription and immutable principal before applying
this Bicep. It does not run estate onboarding or change other apps.

This grant is owned by Bogstavvenner. On app decommission, remove its subscription
role assignment and then its custom role definition; removing the app RG alone
does not remove these subscription resources. Keep this declaration until those
resources are removed. The workflow is idempotent.
