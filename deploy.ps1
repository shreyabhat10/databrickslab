Param(
    [Parameter(Mandatory=$True, HelpMessage="Name of the Resource group to be used for Databricks and VNet")]
    [String]
    $RG_NAME ,

    [Parameter(Mandatory=$True, HelpMessage="Location for all resources")]
    [String]
    $REGION ,

    [Parameter(Mandatory=$True, HelpMessage="The name of the Azure Databricks workspace to create")]
    [String]
    $WORKSPACE_NAME ,

    [Parameter(Mandatory=$True, HelpMessage="Cluster name requested by the user. This doesn't have to be unique")]
    [String]
    $CLUSTER_NAME="testdbcluster",

    [Parameter(Mandatory=$True, HelpMessage="The runtime version of the cluster")]
    [String]
    $CLUSTER_VERSION="11.3.x-scala2.12",

    [Parameter(Mandatory=$True, HelpMessage="Number of worker nodes that this cluster should have (autoscaling is disabled)")]
    [String]
    $CLUSTER_WORKERS_QUANTITY="4",

    [Parameter(Mandatory=$True, HelpMessage="The node type of the Spark worker")]
    [String]
    $CLUSTER_WORKERS_SIZE="Standard_DS3_v2",

    [Parameter(Mandatory=$True, HelpMessage="The node type of the Spark driver")]
    [String]
    $CLUSTER_DRIVER_SIZE="Standard_DS3_v2"
)

if ((Get-Module -ListAvailable Az.Accounts) -eq $null)
	{
       Install-Module -Name Az.Accounts -Force
    }

#Write-Output "Task: Wait for workspace API to become available"
#Start-Sleep -Seconds 120

Write-Output "Task: Generating Databricks Token"
$WORKSPACE_ID = (az resource show --resource-type Microsoft.Databricks/workspaces --resource-group $RG_NAME --name $WORKSPACE_NAME --query id --output tsv)
$TOKEN = (az account get-access-token --resource '2ff814a6-3304-4ab8-85cb-cd0e6f879c1d' | jq --raw-output '.accessToken')
$AZ_TOKEN = (az account get-access-token --resource https://management.core.windows.net/ | jq --raw-output '.accessToken')
$HEADERS = @{
    "Authorization" = "Bearer $TOKEN"
    "X-Databricks-Azure-SP-Management-Token" = "$AZ_TOKEN"
    "X-Databricks-Azure-Workspace-Resource-Id" = "$WORKSPACE_ID"
}
$BODY = @'
{ "lifetime_seconds": 1200, "comment": "ARM deployment" }
'@
$DB_PAT = ((Invoke-RestMethod -Method POST -Uri "https://$REGION.azuredatabricks.net/api/2.0/token/create" -Headers $HEADERS -Body $BODY).token_value)

Write-Output "Task: Creating cluster"
$HEADERS = @{
    "Authorization" = "Bearer $DB_PAT"
    "Content-Type" = "application/json"
}
$BODY = @"
{"cluster_name": "$CLUSTER_NAME", "spark_version": "$CLUSTER_VERSION", "autotermination_minutes": 30, "num_workers": "$CLUSTER_WORKERS_QUANTITY", "node_type_id": "$CLUSTER_WORKERS_SIZE", "driver_node_type_id": "$CLUSTER_DRIVER_SIZE" }
"@
$CLUSTER_ID = ((Invoke-RestMethod -Method POST -Uri "https://$REGION.azuredatabricks.net/api/2.0/clusters/create" -Headers $HEADERS -Body $BODY).cluster_id)
if ( $CLUSTER_ID -ne "null" ) {
    Write-Output "[INFO] CLUSTER_ID: $CLUSTER_ID"
} else {
    Write-Output "[ERROR] cluster was not created"
    exit 1
}

Write-Output "Task: Checking cluster"
$RETRY_LIMIT = 15
$RETRY_TIME = 60
$RETRY_COUNT = 0
for( $RETRY_COUNT = 1; $RETRY_COUNT -le $RETRY_LIMIT; $RETRY_COUNT++ ) {
    Write-Output "[INFO] Attempt $RETRY_COUNT of $RETRY_LIMIT"
    $HEADERS = @{
        "Authorization" = "Bearer $DB_PAT"
    }
    $STATE = ((Invoke-RestMethod -Method GET -Uri "https://$REGION.azuredatabricks.net/api/2.0/clusters/get?cluster_id=$CLUSTER_ID" -Headers $HEADERS).state)
    if ($STATE -eq "RUNNING") {
        Write-Output "[INFO] Cluster is running, pipeline has been completed successfully"
        return
    } else {
        Write-Output "[INFO] Cluster is still not ready, current state: $STATE Next check in $RETRY_TIME seconds.."
        Start-Sleep -Seconds $RETRY_TIME
    }
}
Write-Output "[ERROR] No more attempts left, breaking.."
exit 1
