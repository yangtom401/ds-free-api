# PVE LXC 一键部署脚本
$PVE_IP = "10.0.0.254"
$CTID = 101
$APP_DIR = "/opt/ds-free-api"
$SCRIPT_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

Push-Location $SCRIPT_DIR

$pveTarget = "root@$PVE_IP"
$binDest = "root@${PVE_IP}:/tmp/ds-free-api.bin" -replace '\$', ''
$wasmDest = "root@${PVE_IP}:/tmp/sha3_wasm_bg.7b9ca65ddd.wasm" -replace '\$', ''

Write-Host "[1/4] 上传二进制与 WASM 算力文件到 PVE 宿主机..." -ForegroundColor Cyan
& scp.exe -O -o StrictHostKeyChecking=no "ds-free-api" "root@10.0.0.254:/tmp/ds-free-api.bin"
& scp.exe -O -o StrictHostKeyChecking=no "sha3_wasm_bg.7b9ca65ddd.wasm" "root@10.0.0.254:/tmp/sha3_wasm_bg.7b9ca65ddd.wasm"

Write-Host "[2/4] 停止旧服务..." -ForegroundColor Cyan
& ssh.exe -o StrictHostKeyChecking=no "root@10.0.0.254" "pct exec $CTID -- systemctl stop ds-free-api"

Write-Host "[3/4] 更新容器文件并赋予执行权限..." -ForegroundColor Cyan
& ssh.exe -o StrictHostKeyChecking=no "root@10.0.0.254" "pct push $CTID /tmp/ds-free-api.bin $APP_DIR/ds-free-api; pct exec $CTID -- chmod +x $APP_DIR/ds-free-api"
& ssh.exe -o StrictHostKeyChecking=no "root@10.0.0.254" "pct push $CTID /tmp/sha3_wasm_bg.7b9ca65ddd.wasm $APP_DIR/sha3_wasm_bg.7b9ca65ddd.wasm"
& ssh.exe -o StrictHostKeyChecking=no "root@10.0.0.254" "pct exec $CTID -- rm -rf $APP_DIR/web"

Write-Host "[4/4] 启动并验证服务..." -ForegroundColor Cyan
& ssh.exe -o StrictHostKeyChecking=no "root@10.0.0.254" "pct exec $CTID -- systemctl start ds-free-api"
Start-Sleep -Seconds 2
& ssh.exe -o StrictHostKeyChecking=no "root@10.0.0.254" "pct exec $CTID -- systemctl status ds-free-api"

Pop-Location
Write-Host "`n部署成功！请访问管理面板: http://10.0.0.101:22217/admin" -ForegroundColor Green