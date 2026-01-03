# 🔧 Manually Testing Intune Remediation Scripts on Windows

**Manually test remediation scripts in Intune's SYSTEM context to catch issues early and ensure smooth deployments.** This guide simulates real Intune execution using PSExec, perfect for PowerShell pros managing Windows fleets.[1][2][3]

## 📋 Prerequisites
- **Download PSExec**: Grab it from [Microsoft Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec) and save to `C:\Tools`.[2]
- **Prepare Scripts**: Have `detection.ps1` and `remediation.ps1` ready (e.g., uptime checks or Defender scans).
- **Test Device**: Use a non-prod Windows 10/11 machine; run `Set-ExecutionPolicy Bypass` in elevated PowerShell.[1]

## 🧪 Test Detection Script
1. Open **cmd as Admin** and launch SYSTEM PowerShell:  
   ```
   C:\Tools\psexec.exe -i -s powershell.exe
   ```
2. Navigate to scripts: `cd C:\Path\To\Scripts`.
3. Run: `.\detection.ps1`.  
   ✅ **Exit 0** = Compliant (no action).  
   ❌ **Exit 1** = Triggers remediation.[3][2][1]

## ⚙️ Test Remediation Script
- In the **SYSTEM PowerShell**, force detection to fail (hardcode thresholds, e.g., uptime >15 days).
- Execute: `.\remediation.ps1`.  
  Watch for notifications, registry writes, or reboots (cancel via Task Manager if testing force-reboot logic).[4][3][1]

## 🔍 Verification & Logs
- **Outputs**: Check `Write-Output`/`Write-Warning` in console.
- **IME Logs**: Inspect `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` and `HealthScripts.log`.[5][2][3]
- **Pro Tip**: Test 32/64-bit: Set Intune script to 64-bit; retest with PSExec flags.[1]

**🚀 Quick Test Checklist**  
- [ ] SYSTEM context via PSExec  
- [ ] Exit codes verified  
- [ ] Logs clean  
- [ ] Edge cases (e.g., notifications) passed  


[1](https://www.reddit.com/r/Intune/comments/yrjdnm/testing_proactive_remediation_scripts/)
[2](https://scloud.work/how-to-troubleshoot-intune-remediation-scripts-locally/)
[3](https://www.perplexity.ai/search/938566c2-41bf-4263-abc7-51da9dda6fdd)
[4](https://www.systemcenterdudes.com/how-to-use-intune-remediation-script/)
[5](https://www.youtube.com/watch?v=4Ag-7y5--GM&vl=en)
[6](https://www.perplexity.ai/search/896eed8b-a9d4-4a10-8b9a-35bacb62f68b)
[7](https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/remediations)
