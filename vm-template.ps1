# =====================
#  Creates a new Virtual Machine from a base template
#  Author: @Eduardo Santos
# =====================


# =====================
# Virtual Machine Configuration
# =====================

$VMName          = "vm-teste"
$TemplateSource  = "D:\Templates\template.vhdx"
$VMBasePath      = "D:\VMs"
$VMPath          = "$VMBasePath\$VMName"
$TemplateDisk    = "$VMPath\template.vhdx"

# =====================
# Create Virtual Machine Directory
# =====================

Write-Host ""
Write-Host "Creating VM directory..."

if (!(Test-Path $VMPath)) {
    New-Item -Path $VMPath -ItemType Directory | Out-Null
    Write-Host "Directory created: $VMPath"
}
else {
    Write-Host "Directory already exists."
}

# =====================
# Copy Template Disk
# =====================

Write-Host ""
Write-Host "Copying template disk..."

Copy-Item `
    -Path $TemplateSource `
    -Destination $TemplateDisk `
    -Force

Write-Host "Template copied successfully."

# =====================
# Create Virtual Machine
# =====================

Write-Host ""
Write-Host "Creating Virtual Machine..."

New-VM `
    -Name $VMName `
    -VHDPath $TemplateDisk `
    -Path $VMPath

Write-Host ""
Write-Host " VM $VMName created successfully"
