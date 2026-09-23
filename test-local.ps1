# PowerShell smoke test. Start the agent first (.\run-local.ps1 in another terminal).
#
#   .\test-local.ps1
#   $env:BASE="http://localhost:9000"; .\test-local.ps1

$base = if ($env:BASE) { $env:BASE } else { "http://localhost:8088" }
$pass = 0; $fail = 0

function Check($name, $ok) {
    if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  FAIL  $name" -ForegroundColor Red;   $script:fail++ }
}

function PostJson($path, $bodyObj) {
    try {
        return Invoke-RestMethod -Uri "$base$path" -Method Post `
            -ContentType "application/json" -Body ($bodyObj | ConvertTo-Json -Depth 10)
    } catch { return $null }
}

Write-Host "Testing $base"

Write-Host "`n[1] health"
$h = try { Invoke-RestMethod -Uri "$base/healthz" } catch { $null }
Write-Host "      $($h | ConvertTo-Json -Compress)"
Check "healthz returns ok" ($h -and $h.status -eq "ok")

Write-Host "`n[2] string input"
$r = PostJson "/responses" @{ input = "Respond with a short deployment confirmation." }
Write-Host "      $($r.output_text)"
Check "status completed"     ($r -and $r.status -eq "completed")
Check "has output_text"      ($r -and $r.output_text)
Check "has output[] message" ($r -and $r.output[0].type -eq "message")

Write-Host "`n[3] message-array input (the shape Foundry is most likely to send)"
$r2 = PostJson "/responses" @{
    input = @(@{ role = "user"; content = @(@{ type = "input_text"; text = "hello from the array shape" }) })
}
Check "array input accepted" ($r2 -and $r2.output_text -match "array shape")

Write-Host "`n[4] versioned path alias"
$r3 = PostJson "/v1/responses" @{ input = "alias check" }
Check "/v1/responses works" ($r3 -and $r3.output_text)

Write-Host "`n[5] streaming (SSE)"
$sse = $null
try {
    $body = '{"input":"stream check","stream":true}'
    $sse = (Invoke-WebRequest -Uri "$base/responses" -Method Post `
        -ContentType "application/json" -Body $body).Content
} catch { }
Check "emits response.completed" ($sse -and $sse -match "response.completed")

Write-Host "`n-------------------------------"
Write-Host "  $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
