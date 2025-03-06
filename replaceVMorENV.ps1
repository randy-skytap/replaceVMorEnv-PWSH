<#
Get environment
pick a vm



#single vm
list attributes.
-nics
-networks connected.
-disks
-ram
-cpu
-name
-etc

Challenges



#>


# Script variables
$content = 'application/json'
$environment_id = '182828556'
$vm_ids = @('122920849')

# Skytap connection information
$cred_sky = Get-Credential -UserName 'randy_isv' -Message "Provide Skytap API Token"
$baseAuth_sky = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $cred_sky.UserName, $cred_sky.GetNetworkCredential().Password)))
$header_sky =  @{Authorization=("Basic {0}" -f $baseAuth_sky); "Content_type" = $content; "accept" = $content}
$uri = 'https://cloud.skytap.com/'

###########################################     VARIABLES   ########################################
###########################################     FUNCTIONS   ########################################

# Simplifies get requests to system.  
Function get_skytap ($r) {
    $path = if($r -match $uri){$r} else { $uri + $r}
    $result = Invoke-RestMethod -uri $path -WebSession $session 
    return, $result
}

# Simplifies setting things like environment runstate, adding vm, etc.
Function set_skytap ($pth, $jsn, $method) {
    $path = if($pth -match $uri){$pth} else {$uri + $pth}
    $json = $jsn | convertto-json
    $action = if($method -ne $null){$method} else {'POST'}
    Invoke-RestMethod -uri $path -WebSession $session -Method $action -body $json -ContentType $content
}


###########################################     FUNCTIONS   ########################################
###########################################      ACTIONS    ########################################
# Connect to Skytap
Invoke-RestMethod -uri $uri -Headers $header_sky -Method GET -sessionvariable session 

# get environment details to replicate
$environment_v2 = get_skytap "v2/configurations/$($environment_id).json"

<#
if we are recreating everything, we need a template id to start with.  
I don't like the concept of template based model since the environment is likely
to vary environment to environment anyways
#> 
#get a skytap template from the same region
$template = get_skytap "v2/templates?&count=1&offset=0&scope=public&query=region:$($environment_v2.region),name:win*"

# create a new environment from the template
$environment_new = set_skytap 'configurations.json' @{template_id=$template[0].id} 'POST'

#setup networks, wans, vms,, etc.  may be faster to setup VMs first

# try copying environment with none of the VMs.
$json_copy = @{
    "configuration_id"= $environment_v2.id;
    "vm_ids"= @('122920849','122920847');
    "live_copy" = true
}

$json_copy = @{
    "configuration_id"= $environment_v2.id;
    "live_copy" = true
}




$create = set_skytap 'configurations.json' $json_copy 'POST'
$create

$json_network = @{
    "networks" = $environment_v2.networks
}

$testpth = "https://cloud.skytap.com/configurations/182835806.json"
$update = set_skytap $testpth $json_network 'PUT'


####### starting to look at just a particular vm id(s)
foreach($v in $vm_ids){
   $vm = get_skytap "vms/$($v)"
   $env = get_skytap "$($vm.configuration_url)"
      #have the vm details and environment details.
   #add a similar vm from skytap public library
   #remove 'bad' vm.
   #update similar vm profile to match that of the removed vm.  
   <#
   name, hardware,  interfaces, notes, labels, credentials
   #>
    # boot
    # attach asset
    # send restart?
}




