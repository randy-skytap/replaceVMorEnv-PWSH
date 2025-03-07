<#
DECLARE
  -VM to replace.
  -Template VM for recovery
  -ISO to mount.

REBUILD targeted VM and rebuild certain attributes.
  -Name, Network Card(s), Disk(s), RAM, CPU

START new VM to MOUNT ISO then RESTART
#>

# Script variables
$vm_ids = @('<VM ID 1>','<VM ID 2>') # <----- Provide new ID everytime
$template_recovery_id = '<Template ID>' # template has no nic, network, or disk.  holds guest os value.
$asset_id = '<Asset ID>'  # <-------- Asset ID will vary based on region.

# Skytap connection information
$content = 'application/json'
$cred_sky = Get-Credential -UserName '<Skytap User>' -Message "Provide Skytap API Token"
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

# Check for runstate
Function busyness ($b){
    Write-Output "Checking for busy resource:  $($b)"
    $i = 0
	$check = get_skytap $b
	while($i -ne 3 -and $check.busy -ne $null){
		write-output "Busy Resource:  $($check.id) $($check.name)"
		$i++
		$check = get_skytap $b
		sleep -Seconds 10
	}
	#return, $check
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
$connect_skytap = Invoke-RestMethod -uri $uri -Headers $header_sky -Method GET -sessionvariable session 

$recover_template = get_skytap "templates/$($template_recovery_id)"

####### starting to look at just a particular vm id(s)
foreach($v in $vm_ids){
    # VM information   
    write-host 'Get VM information'
    $vm = get_skytap "vms/$($v)"

    # Use DR template VM for that region.  Removed NIC for merging simplicity.
    write-host 'Add recovery VM '
    $add_vm = set_skytap "$($vm.configuration_url).json" @{template_id = $template_recovery_id} 'PUT'
    
    # Delete VM.  This $vm has the detail to use going forward.
    write-host 'Delete source VM'
    $delete_vm = set_skytap "vms/$($vm.id)" '' 'DELETE'

    # Update new vm
    write-host 'Update new VM'
    $new_vm = $add_vm.vms | ? {$_.name -like $recover_template.vms[0].name}
    
    # Add disk1 then others
    write-host 'Organize Disk information'
    $disk1 = $vm.hardware.disks | ? {$_.controller -like '0' -and $_.lun -like '0'}  
    $disks = @($disk1.size)
    foreach($d in ($vm.hardware.disks |? {$_.id -ne $disk1.id})){$disks += $d.size}

    # Update hardware
    write-host 'Update Hardware settings'
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
    $update_hardware = set_skytap "vms/$($new_vm.id)" $json_hardware 'PUT'


    # Create network cards and add to corresponding network.
    foreach($nic in $vm.interfaces){
        write-host "Add NIC ($($nic.hostname))"
        sleep -Seconds 20
        busyness "$($vm.configuration_url)/vms/$($new_vm.id).json"
        $add_nic = set_skytap "$($vm.configuration_url)/vms/$($new_vm.id)/interfaces.json" @{nic_type= $nic.nic_type} 'POST'

        write-host "Sleep then connect nic ($($nic.hostname)) to network $($nic.network_id)"
        sleep -Seconds 20
        busyness "$($vm.configuration_url)/vms/$($new_vm.id).json"
        $connect_network = set_skytap "$($vm.configuration_url)/vms/$($new_vm.id)/interfaces/$($add_nic.id).json" @{network_id= $nic.network_id} 'PUT'
        
        write-host "Sleep then update nic ($($nic.id)) ip $($nic.ip); host $($nic.hostname); mac $($nic.mac)"
        sleep -Seconds 20
        busyness "$($vm.configuration_url)/vms/$($new_vm.id).json"
        $json_update_nic = @{
            ip= $nic.ip;
            hostname= $nic.hostname;
            mac= $nic.mac
        }
        $update_nic = set_skytap "$($vm.configuration_url)/vms/$($new_vm.id)/interfaces/$($add_nic.id).json" $json_update_nic 'PUT'
    }
  
    # Boot
    write-host "Start New VM"
    $start_vm = set_skytap "vms/$($new_vm.id).json" @{runstate="running"} 'PUT'
    sleep -Seconds 60

    # Mount ISO (asset)
    busyness $vm.configuration_url
    write-host "Mount ISO"
    $mount_iso = set_skytap "vms/$($new_vm.id)" @{asset_id= $asset_id} 'PUT'
    
    # Restart
    busyness $vm.configuration_url
    write-host "Restart New VM"
    $restart_vm = set_skytap "vms/$($new_vm.id).json" @{runstate="reset"} 'PUT'

}
