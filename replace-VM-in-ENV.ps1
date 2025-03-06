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
- adding disks beyond standard sizing won't execute.  
- The DR template should have disks set to the max size needed

#>


# Script variables
$content = 'application/json'
$vm_ids = @('1229491643240') # <----- Provide new ID everytime
$templates_recovery = '232236083797' # template has no nic, network, or disk.  holds guest os value.
$asset_id = '65504645641'  # <-------- Asset ID will vary based on region.

# Skytap connection information
$cred_sky = Get-Credential -UserName '<skytap user>' -Message "Provide Skytap API Token"
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

#check for runstate
Function busyness ($b){
    $i = 0
	$check = get_skytap $b
	while($i -ne 3 -and $check.busy -ne $null){
		write-output 'inside while'
		$i++
		$check = get_skytap $b
		sleep $delay
	}
	return, $check
}

# Simplifies setting things like environment runstate, adding vm, etc.
Function set_skytap ($pth, $jsn, $method) {
    $path = if($pth -match $uri){$pth} else {$uri + $pth}
    $json = $jsn | convertto-json -Depth 99
    $action = if($method -ne $null){$method} else {'POST'}
    Invoke-RestMethod -uri $path -WebSession $session -Method $action -body $json -ContentType $content
}


###########################################     FUNCTIONS   ########################################
###########################################      ACTIONS    ########################################
# Connect to Skytap
Invoke-RestMethod -uri $uri -Headers $header_sky -Method GET -sessionvariable session 

####### starting to look at just a particular vm id(s)
foreach($v in $vm_ids){
    #vm detail   
    $vm = get_skytap "vms/$($v)"
    #environment detail
    $environment = get_skytap "$($vm.configuration_url)"
    $recover_template = get_skytap "templates/$($templates_recovery)"

    <# 
    find public template
    $templates = get_skytap "v2/templates?&count=100&offset=0&scope=public&query=region:$($environment.region),name:win*"
    $template = ($templates | ? {$_.vms.hardware.guestos -eq $vm.hardware.guestos}) | select -First 1
    #>

    # Use DR template VM for that region.  removed NIC for merging simplicity.
    $add_vm = set_skytap "$($vm.configuration_url).json" @{template_id = $templates_recovery} 'PUT'
    
    # Delete VM
    $destroy_vm = set_skytap "vms/$($vm.id)" '' 'DELETE'

    # Update new vm
    $new_vm = $add_vm.vms | ? {$_.name -like $recover_template.vms[0].name}
    
    #add disk1 then rest 
    $disk1 = $vm.hardware.disks | ? {$_.controller -like '0' -and $_.lun -like '0'}
    $disks = @($disk1.size)
    foreach($d in ($vm.hardware.disks |? {$_.id -ne $disk1.id})){$disks += $d.size}

    # update hardware
    $json_hardware = @{
        name= $vm.name;
        hardware=@{
            ram= $vm.hardware.ram;
            disks=@{
                new= $disks
            };
            cpus= $vm.hardware.cpus;
            cpus_per_socket = $vm.hardware.cpus_per_socket
        }
    } 
    $update_hardware = set_skytap "vms/$($new_vm.id)" $json_ram 'PUT'


    # Create network cards and add to corresponding network.
    foreach($nic in $vm.interfaces){
        busyness $vm.configuration_url
        $add_nic = set_skytap "$($vm.configuration_url)/vms/$($new_vm.id)/interfaces.json" @{nic_type= $nic.nic_type} 'POST'
        busyness $vm.configuration_url

        $connect_network = set_skytap "$($vm.configuration_url)/vms/$($new_vm.id)/interfaces/$($add_nic.id).json" @{network_id= $nic.network_id} 'PUT'
        busyness $vm.configuration_url

        $json_update_nic = @{
            ip= $nic.ip;
            hostname= $nic.hostname;
            mac= $nic.mac
        }
        $update_nic = set_skytap "$($vm.configuration_url)/vms/$($new_vm.id)/interfaces/$($add_nic.id).json" $json_update_nic 'PUT'
    }
  
    # boot
    $start_vm = set_skytap "vms/$($new_vm.id).json" @{runstate="running"} 'PUT'

    # attach asset
    busyness $vm.configuration_url
    $mount_iso = set_skytap "vms/$($new_vm.id)" @{asset_id= $asset_id} 'PUT'
    # send restart?
    busyness $vm.configuration_url
    $restart_vm = set_skytap "vms/$($new_vm.id).json" @{runstate="reset"} 'PUT'
}

