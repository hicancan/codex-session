"use strict";
const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer-core');

// 动态读取配置，避免将隐私数据硬编码提交到 Git
const configPath = path.join(__dirname, 'config.json');
if (!fs.existsSync(configPath)) {
    console.error("缺少 config.json！请从 config.example.json 复制一份并填入你的企业配置。");
    process.exit(1);
}
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const WORKSPACE_ID = config.WORKSPACE_ID;
const PROTECTED_USER_ID = config.PROTECTED_USER_ID;

async function switchSeat(targetEmail) {
    let browser;
    let page = null;
    let connected = false;
    
    // 1. 等待并连接 Chrome 逻辑
    for (let i = 0; i < 5; i++) {
        try {
            browser = await puppeteer.connect({
                browserURL: 'http://127.0.0.1:9222',
                defaultViewport: null
            });
            connected = true;
            break;
        } catch (err) {
            if (i === 0) {
                console.error("[Info] Browser process not detected. Invoking Chrome shortcut...");
                const { exec } = require('child_process');
                const os = require('os');
                const desktopPath = path.join(os.homedir(), 'Desktop', 'Google Chrome (API模式).lnk');
                exec(`start "" "${desktopPath}"`, (err) => {
                    if (err) console.error("[Error] Failed to invoke Chrome:", err.message);
                });
                console.error("[Polling] Waiting for CDP port 9222 to bind (Timeout: 15s)...");
            }
            await new Promise(r => setTimeout(r, 3000));
        }
    }

    if (!connected) {
        console.error("[Error] Connection to Chrome CDP (port 9222) timed out. Aborting allocation.");
        process.exitCode = 1;
        return;
    }

    try {
        // 2. 等待管理页面打开逻辑
        for (let i = 0; i < 30; i++) {
            const pages = await browser.pages();
            page = pages.find(p => p.url().includes('chatgpt.com/admin/members'));
            if (page) break;
            
            if (i === 0) {
                console.error("\n[Pending] Connected to CDP. Target administrative page context not found.");
                console.error("[Action Required] To satisfy Cloudflare Turnstile constraints, please manually open a new tab and navigate to:");
                console.error("URL: https://chatgpt.com/admin/members");
                console.error("[Polling] Waiting for page context (Timeout: 60s)...");
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        
        if (!page) {
            console.error("[Error] Page context polling timed out. Aborting allocation.");
            process.exitCode = 1;
            return;
        }
        console.error("[Success] Target page context acquired. Executing seat reallocation...");

        const result = await page.evaluate(async (workspaceId, protectedId, targetEmail) => {
            try {
                const fetchWithTimeout = async (url, options = {}) => {
                    options.signal = AbortSignal.timeout(15000);
                    return await fetch(url, options);
                };

                // 1. Session Token
                const sessionRes = await fetchWithTimeout('/api/auth/session');
                const session = await sessionRes.json();
                if (!session.accessToken) return { success: false, error: "Not logged in to ChatGPT" };
                const token = session.accessToken;
                
                const headers = {
                    "Authorization": "Bearer " + token,
                    "content-type": "application/json"
                };

                // 2. Members List (Pagination support)
                let members = [];
                let offset = 0;
                while (true) {
                    const usersRes = await fetchWithTimeout(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users?offset=${offset}&limit=100`, { headers });
                    const usersData = await usersRes.json();
                    if (!usersData.items || usersData.items.length === 0) break;
                    members.push(...usersData.items);
                    offset += 100;
                }
                
                let targetUser = members.find(u => u.email === targetEmail);
                if (!targetUser) return { success: false, error: `Target email not found: ${targetEmail}` };
                if (targetUser.plan_type === 'default' || targetUser.seat_type === 'default') {
                    return { success: true, msg: "Target already has ChatGPT seat." };
                }

                // 3. Find Idle User
                let userToDemote = members.find(u => 
                    (u.plan_type === 'default' || u.seat_type === 'default') && 
                    u.id !== protectedId
                );

                if (userToDemote) {
                    const demoteRes = await fetchWithTimeout(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users/${userToDemote.id}`, {
                        method: "PATCH",
                        headers,
                        body: JSON.stringify({ seat_type: "usage_based" })
                    });
                    if (!demoteRes.ok) {
                        const demoteErr = await demoteRes.text().catch(() => '');
                        throw new Error(`[Fatal Error] Seat demotion failed with HTTP ${demoteRes.status}: ${demoteErr}`);
                    }
                }

                // 4. Upgrade Target
                const upgradeRes = await fetchWithTimeout(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users/${targetUser.id}`, {
                    method: "PATCH",
                    headers,
                    body: JSON.stringify({ seat_type: "default" })
                });

                if (upgradeRes.ok) {
                    return { success: true, msg: `Seat Drift Complete: -> ${targetEmail}` };
                } else {
                    const errText = await upgradeRes.text();
                    
                    // 5. ROLLBACK DEMOTION on Upgrade Failure
                    if (userToDemote) {
                        try {
                            await fetchWithTimeout(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users/${userToDemote.id}`, {
                                method: "PATCH",
                                headers,
                                body: JSON.stringify({ seat_type: "default" })
                            });
                        } catch (rollbackErr) {
                            return { success: false, error: `CRITICAL STATE LEAK: Upgrade failed (${upgradeRes.status}) AND Rollback failed: ${rollbackErr.message}` };
                        }
                    }
                    
                    return { success: false, error: `Upgrade failed: ${upgradeRes.status} - ${errText}. Demotion was safely rolled back.` };
                }

            } catch (e) {
                return { success: false, error: e.message };
            }
        }, WORKSPACE_ID, PROTECTED_USER_ID, targetEmail);
        
        console.log(result);
        
        if (!result.success) {
            process.exitCode = 1;
        }

    } catch (err) {
        console.error("执行席位漂移期间发生错误:", err.message);
        process.exitCode = 1;
    } finally {
        if (browser) browser.disconnect();
    }
}

const target = process.argv[2];
if (!target) {
    console.log("用法: node seat-manager.js <目标邮箱>");
    process.exit(1);
}

switchSeat(target);
