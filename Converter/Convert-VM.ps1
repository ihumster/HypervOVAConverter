#Requires -Version 4
#Requires -Modules Hyper-V
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName="HVVM")]
Param (
[Parameter(Mandatory=$True,ParameterSetName="HVVM")]
[string]$HyperVVMPath,
[Parameter(Mandatory=$True,ParameterSetName="VHD")]
[string]$VHDPath,
[Parameter(Mandatory=$True)]
[string]$OVAPath,
[Parameter(ParameterSetName="VHD")]
[byte]$CPU = 1,
[Parameter(ParameterSetName="VHD")]
[int]$Memory = 1024
)

#region Consts
$vmcfgfolder = "Virtual Machines"
$vmhddfolder = "Virtual Hard Disks"
$converterfullpath = "$PSScriptRoot\StarV2Vc.exe"
$ovftoolfullpath = "$PSScriptRoot\ovftool\ovftool.exe"
#endregion

#region HeaderConfig
$config = @'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "9"
scsi0.virtualDev = "lsisas1068"
scsi0.present = "TRUE"

'@
#endregion

#Проверяем наличие папки для целевых файлов
if (-not (Test-Path -Path $OVAPath -PathType Container)) {
    New-Item -ItemType Directory -Path $OVAPath -Force
}


Switch ($PSCmdlet.ParameterSetName)
{
    "HVVM" {
        #Получаем конфиг экспортируемой ВМ
        $vmconfig = Join-Path -Path $HyperVVMPath -ChildPath $vmcfgfolder

        if (Test-Path $vmconfig -PathType Container) {
            $vmcfg = Get-ChildItem -Path $vmconfig | ?{$_.Extension -eq ".xml" -or $_.Extension -eq ".vmcx"}

            if ($vmcfg.Count -eq 1) {
        
                $VM = (Compare-VM -Path $(Join-Path -Path $vmconfig -ChildPath $vmcfg.Name) -GenerateNewId -Copy).VM
            }
            else {
                Write-Host -ForegroundColor Red "Ошибка: $vmcfgpath не содержит файлов конфигурации виртуальной машины или их более одной"
                Exit
            }

        }
        else {
            Write-Host -ForegroundColor Red "Ошибка: $HyperVVMPath не содержит файлов конфигурации виртуальной машины"
            Exit
        }

        #Собираем конфиг VMX
        $config += "displayName = `"$($VM.VMName)`"`r`n"
        $config += "numvcpus = `"$($VM.ProcessorCount)`"`r`n"
        if ($vm.DynamicMemoryEnabled) {
            $config += "memSize = `"$([math]::Round($vm.MemoryMaximum/1MB,0))`"`r`n"
        }
        else {
            $config += "memSize = `"$([math]::Round($vm.MemoryStartup/1MB,0))`"`r`n"
        }

        $i = 0
        foreach ($nwa in $vm.NetworkAdapters){
            $config += "ethernet$i.virtualDev = `"vmxnet3`"`r`n"
            $config += "ethernet$i.addressType = `"vpx`"`r`n"
            $config += "ethernet$i.present = `"TRUE`"`r`n"

            $i++
        }

        $i = 0
        foreach ($hd in $vm.HardDrives) {
            $vhdrootpath = Join-Path -Path $HyperVVMPath -ChildPath $vmhddfolder
        
            $vhdname = Split-Path -Path $hd.Path -Leaf
            $vhdfullpath = Join-Path -Path $vhdrootpath -ChildPath $vhdname

            if (($vhdfullpath | Get-VHD).VhdFormat -eq 'VHDX') {
                $outfullpath = $vhdfullpath.TrimEnd("vhdx") + "vmdk"
            }
            else {
                $outfullpath = $vhdfullpath.TrimEnd("vhd") + "vmdk"
            }
    
            $outname = Split-Path -Path $outfullpath -Leaf

            $outvmdkpath = Join-Path -Path $OVAPath -ChildPath $outname

            $arglist = "if=`"$vhdfullpath`" of=`"$outvmdkpath`" ot=VMDK_S vmdktype=SCSI"

            Start-Process -FilePath $converterfullpath -ArgumentList $arglist -Wait

            $config += "scsi0:$i.deviceType = `"scsi-hardDisk`"`r`n"
            $config += "scsi0:$i.fileName = `"$outname`"`r`n"
            $config += "scsi0:$i.present = `"TRUE`"`r`n"
            
            $i++
        }

        $path = Join-Path -Path $OVAPath -ChildPath $($vm.Name + ".vmx")
    }

    "VHD" {
        If (Test-Path -Path $VHDPath -PathType Leaf)
        {
            $vhdname = Split-Path -Path $VHDPath -Leaf
        

            If (($VHDPath | Get-VHD).VhdFormat -eq 'VHDX')
            {
                $VMName = $vhdname.TrimEnd(".vhdx")
                $outfullpath = $VHDPath.TrimEnd("vhdx") + "vmdk"
            }
            else {
                $VMName = $vhdname.TrimEnd(".vhd")
                $outfullpath = $VHDPath.TrimEnd("vhd") + "vmdk"            
            }

            #собираем конфиг
            $config += "displayName = `"$($VMName)`"`r`n"
            $config += "numvcpus = `"$($CPU)`"`r`n"
            $config += "memSize = `"$($Memory)`"`r`n"
            $config += "scsi0:0.deviceType = `"scsi-hardDisk`"`r`n"
            $config += "scsi0:0.fileName = `"$($VMName+".vmdk")`"`r`n"
            $config += "scsi0:0.present = `"TRUE`"`r`n"
            $config += "ethernet0.virtualDev = `"vmxnet3`"`r`n"
            $config += "ethernet0.addressType = `"vpx`"`r`n"
            $config += "ethernet0.present = `"TRUE`"`r`n"

            $path = Join-Path -Path $OVAPath -ChildPath $($VMName + ".vmx")

            $outname = Split-Path -Path $outfullpath -Leaf

            $outvmdkpath = Join-Path -Path $OVAPath -ChildPath $outname

            $arglist = "if=`"$VHDPath`" of=`"$outvmdkpath`" ot=VMDK_S vmdktype=SCSI"

            Start-Process -FilePath $converterfullpath -ArgumentList $arglist -Wait
        }
        else
        {
            Write-Host -ForegroundColor Red "Ошибка: $VHDPath не является файлом"
            Exit
        }
    }

}

#сохраняем конфиг
Set-Content -Path $path -Value $config

#Заворачиваем ВМ в OVA
$ovafilepath = $path.TrimEnd("vmx") + "ova"

$arglist = "$path $ovafilepath"

Start-Process -FilePath $ovftoolfullpath -ArgumentList $arglist -Wait

Write-Host -ForegroundColor Green "OVA-файл находится тут: $ovafilepath"