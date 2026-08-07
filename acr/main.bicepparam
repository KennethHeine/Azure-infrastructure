using './main.bicep'

// sp-azure-infrastructure-github — the control-plane onboarding SP this repo's
// workflows run as. Needs registry-wide Repository Contributor + Catalog Lister
// so decommission-repo.ps1 (Step 3d) can purge a torn-down repo's images from
// the shared registry; under ABAC its subscription Owner role grants it nothing
// on the data plane.
param controlPlanePrincipalId = '4d0863fa-5c70-4b02-a413-566dbf98a3ea'

// Human operators who need to be able to inspect the registry (Catalog Lister
// + Repository Reader). Object ids, not UPNs — a UPN lookup would need a Graph
// read this deployment doesn't otherwise require.
param operatorPrincipalIds = [
  'b8df5049-1dac-470e-b653-7772c72c4611' // kenneth@kscloud.io
]
