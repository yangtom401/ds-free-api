# PVE LXC 一键部署脚本
$PVE_IP = "10.0.0.254"
$CTID = 101
$APP_DIR = "/opt/ds-free-api"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "[1/4] 上传二进制与 WASM 算力文件到 PVE 宿主机..." -ForegroundColor Cyan
scp -O -o StrictHostKeyChecking=no "$SCRIPT_DIR/ds-free-api" "root@${PVE_IP}:/tmp/ds-free-api.bin"
scp -O -o StrictHostKeyChecking=no "$SCRIPT_DIR/sha3_wasm_bg.7b9ca65ddd.wasm" "root@${PVE_IP}:/tmp/sha3_wasm_bg.7b9ca65ddd.wasm"

Write-Host "[2/4] 停止旧服务..." -ForegroundColor Cyan
ssh -o StrictHostKeyChecking=no "root@$PVE_IP" "pct exec $CTID -- systemctl stop ds-free-api"

Write-Host "[3/4] 更新容器文件并赋予执行权限..." -ForegroundColor Cyan
ssh -o StrictHostKeyChecking=no "root@$PVE_IP" "pct push $CTID /tmp/ds-free-api.bin $APP_DIR/ds-free-api; pct exec $CTID -- chmod +x $APP_DIR/ds-free-api"
ssh -o StrictHostKeyChecking=no "root@$PVE_IP" "pct push $CTID /tmp/sha3_wasm_bg.7b9ca65ddd.wasm $APP_DIR/sha3_wasm_bg.7b9ca65ddd.wasm"
ssh -o StrictHostKeyChecking=no "root@$PVE_IP" "pct exec $CTID -- rm -rf $APP_DIR/web"

Write-Host "[4/4] 启动并验证服务..." -ForegroundColor Cyan
ssh -o StrictHostKeyChecking=no "root@$PVE_IP" "pct exec $CTID -- systemctl start ds-free-api"
Start-Sleep -Seconds 2
ssh -o StrictHostKeyChecking=no "root@$PVE_IP" "pct exec $CTID -- systemctl status ds-free-api"

Write-Host "`n部署成功！请访问管理面板: http://10.0.0.101:22217/admin" -ForegroundColor Green