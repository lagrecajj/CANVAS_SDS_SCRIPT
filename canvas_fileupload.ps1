﻿##########Canfile Upload##########
#check configuration file is available or not
param(
      [Parameter(Mandatory=$true)][System.String]$Username,
      [Parameter(Mandatory=$true)][System.String]$Password,
      [Parameter(Mandatory=$true)][System.String]$SyncprofileName
      )

if (-not (test-path conf.json))
{
#connect AzureAD
$secpasswd = ConvertTo-SecureString $Password -AsPlainText -Force
$mycreds = New-Object System.Management.Automation.PSCredential ($Username, $secpasswd)
$res = Connect-AzureAD -Credential $mycreds


#create Azure application
        $appName = 'connectsds'
        $appHomePageUrl = 'http://sissync.microsoft.com'
        $appURI = "http://sissync.microsoft.com/connectsds"
        $appReplyURLs = "https://localhost:1234"

##required resourceAccess
$svcprincipal = Get-AzureADServicePrincipal -All $true | ? { $_.DisplayName -match "Microsoft Graph" }
$reqGraph = New-Object -TypeName "Microsoft.Open.AzureAD.Model.RequiredResourceAccess"
$reqGraph.ResourceAppId = $svcprincipal.AppId

##ResourceAccess-  Delegated Permissions
$delPermission1 = New-Object -TypeName "Microsoft.Open.AzureAD.Model.ResourceAccess" -ArgumentList "0e263e50-5827-48a4-b97c-d940288653c7","Scope" #Access Directory as the signed in user
$appPermission1 = New-Object -TypeName "Microsoft.Open.AzureAD.Model.ResourceAccess" -ArgumentList 63589852-04e3-46b4-bae9-15d5b1050748,"Scope" 
$appPermission2 = New-Object -TypeName "Microsoft.Open.AzureAD.Model.ResourceAccess" -ArgumentList 8523895c-6081-45bf-8a5d-f062a2f12c9f,"Scope"

#apply permistions to app
$reqGraph.ResourceAccess = $delPermission1, $appPermission1, $appPermission2

if(!($myApp = Get-AzureADApplication -Filter "DisplayName eq '$($appName)'"  -ErrorAction SilentlyContinue))
{
    $myApp = New-AzureADApplication -DisplayName $appName -IdentifierUris $appURI -Homepage $appHomePageUrl -ReplyUrls $appReplyURLs -RequiredResourceAccess $reqGraph    
}

# Application (client) ID, tenant Name
$client_Id = (Get-AzureADApplication -Filter "DisplayName eq '$($appName)'" | select AppId).AppId
$ObjectId = (Get-AzureADApplication -Filter "DisplayName eq '$($appName)'" | select ObjectId).ObjectId
$resource = "https://graph.microsoft.com/"
$tenant = Get-AzureADTenantDetail
$tenantid = $tenant.ObjectId
$Domaininfo = $tenant.VerifiedDomains
$Domain = $Domaininfo.Name

#Grant Adminconsent
$Grant= 'https://login.microsoftonline.com/common/adminconsent?client_id='
$admin = '&state=12345&redirect_uri=https://localhost:1234'
$Grantadmin= $Grant + $client_Id + $admin

start $Grantadmin

#Getting SKuid
$skuid = Get-AzureADSubscribedSku | select 
$studentskuIds = $skuid | where {($_.skuPartNumber -eq 'M365EDU_A5_STUDENT')}
$studentskuIds.skuId
$teacherskuIds = $skuid | where {($_.skuPartNumber -eq 'M365EDU_A5_FACULTY')}
$teacherskuIds.skuId
$studentlicense = $studentskuIds.skuId
$teacherlicense = $teacherskuIds.skuId

#creating client secret
$startDate = Get-Date
$endDate = $startDate.AddYears(3)
$clientSecret = New-AzureADApplicationPasswordCredential -ObjectId $ObjectId -CustomKeyIdentifier "Secret" -StartDate $startDate -EndDate $endDate
$Client_Secret = $clientSecret.Value


        
    $conf = [ordered]@{
    SyncprofileName= $SyncprofileName    
    client_Id     = $client_Id
    Client_Secret = $Client_Secret
    Username      = $Username
    Password      = $Password
    Tenantid      = $tenantid
    Domain        = $Domain
    Teacherlicense= $teacherlicense
    Studentlicense= $studentlicense
    }

$conf | ConvertTo-Json | Out-File -FilePath conf.json

}

else
  {
    $conffile = get-content conf.json | ConvertFrom-Json
  
    $SyncprofileName= $conffile.SyncprofileName
    $client_Id     = $conffile.client_Id
    $Client_Secret = $conffile.Client_Secret
    $Username      = $conffile.Username
    $Password      = $conffile.Password
    $tenantid      = $conffile.Tenantid
    $Domain        = $conffile.Domain
    $teacherlicense    = $conffile.Teacherlicense
    $studentlicense    = $conffile.Studentlicense
    }
    ##Token generation
    $loginurl = "https://login.microsoftonline.com/" + "$tenantid" + "/oauth2/v2.0/token"

    $ReqTokenBody = @{
     Grant_Type    = "Password"
    client_Id     = $client_Id
    Client_Secret = $Client_Secret
    Username      = $Username
    Password      = $Password
    Scope         = "https://graph.microsoft.com/.default"
} 

$Token = Invoke-RestMethod -Uri "$loginurl" -Method POST -Body $ReqTokenBody


# Create header
$Header = @{
    Authorization = "$($token.token_type) $($token.access_token)"
}

#####create synchronization profiles####

$body =
@{
    displayName = $SyncprofileName
    dataProvider = 
        @{(odata.type) = "#Microsoft.Education.DataSync.educationCsvDataProvider"
        customizations = {
            student = {optionalPropertiesToSync = ("State ID", "Middle Name")}
        }
    }
    identitySynchronizationConfiguration = 
        @{(data.type) = "#Microsoft.Education.DataSync.educationIdentityCreationConfiguration"
        userDomains = {
            {
                appliesTo = "teacher",
                name = $Domain
            },
            {
                appliesTo = "teacher",
                name = $Domain
            }
        }
    }
    licensesToAssign = {
        {
            appliesTo = "teacher",
            skuIds = $teacherlicense
             },
        {
            appliesTo = "student",
            skuIds = $studentlicense
            }
    }
}

$createdprofile = Invoke-RestMethod -Headers $Header -Uri 'https://graph.microsoft.com/beta/education/synchronizationProfiles' -Body $body -Method Post -ContentType 'application/json'
$NewsyncID = $createdprofile.id

#create upload url
$Uri1 = "https://graph.microsoft.com/beta/education/synchronizationProfiles/" + "$NewsyncID" + "/uploadurl"
$uploadurl = Invoke-RestMethod -Uri $Uri1 -Headers $Header -Method Get -ContentType "application/json"

$b = $uploadurl.value
$a = 'C:\azcopy\azcopy.exe copy "C:\local\*.*" '
$c = ' --recursive=true --check-length=false'

$u = "$a" + "'$b'" + "$c"
$u >sastoken.cmd

#run azcopy file and upload files using azcopy
start-process -FilePath sastoken.cmd

#Run start sync profile
$UriStart = "https://graph.microsoft.com/beta/education/synchronizationProfiles/" + "$NewsyncID" + "/start"
$start = Invoke-RestMethod -Uri $UriStart -Headers $Header -Method Post -ContentType "application/json"
$start

