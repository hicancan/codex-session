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
                console.error("[!] 未检测到浏览器运行，已自动为您启动 Chrome (API模式)...");
                const { exec } = require('child_process');
                const os = require('os');
                const desktopPath = path.join(os.homedir(), 'Desktop', 'Google Chrome (API模式).lnk');
                exec(`start "" "${desktopPath}"`);
                console.error("    脚本将挂起等待浏览器完全开启 (最多等待 15 秒)...");
            }
            await new Promise(r => setTimeout(r, 3000));
        }
    }

    if (!connected) {
        console.error("[!] 浏览器启动超时或 9222 端口无法连接。本地凭证未切换。");
        process.exitCode = 1;
        return;
    }

    try {
        // 2. 等待管理页面打开逻辑
        let page = null;
        for (let i = 0; i < 30; i++) {
            const pages = await browser.pages();
            page = pages.find(p => p.url().includes('chatgpt.com/admin/members'));
            if (page) break;
            
            if (i === 0) {
                console.error("\n[!] 浏览器运行正常，但【未打开】企业管理页面！");
                console.error("    为规避 Cloudflare 拦截，请您手动在浏览器中新建标签页并访问:");
                console.error("    👉 https://chatgpt.com/admin/members");
                console.error("    等待页面加载完成 (最多等待 60 秒)...");
            }
            await new Promise(r => setTimeout(r, 2000));
        }
        
        if (!page) {
            console.error("[!] 等待超时。本地凭证未切换。");
            process.exitCode = 1;
            return;
        }
        console.error(">>> 检测到合法环境！免死金牌已就绪，开始急速漂移...");

        const result = await page.evaluate(async (workspaceId, protectedId, targetEmail) => {
            try {
                // 1. Session Token
                const sessionRes = await fetch('/api/auth/session');
                const session = await sessionRes.json();
                if (!session.accessToken) return { success: false, error: "Not logged in to ChatGPT" };
                const token = session.accessToken;
                
                const headers = {
                    "Authorization": "Bearer " + token,
                    "content-type": "application/json"
                };

                // 2. Members List
                const usersRes = await fetch(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users?offset=0&limit=50`, { headers });
                const usersData = await usersRes.json();
                if (!usersData.items) return { success: false, error: "Failed to fetch members" };
                
                const members = usersData.items;
                
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
                    await fetch(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users/${userToDemote.id}`, {
                        method: "PATCH",
                        headers,
                        body: JSON.stringify({ seat_type: "usage_based" })
                    });
                }

                // 4. Upgrade Target
                const upgradeRes = await fetch(`https://chatgpt.com/backend-api/accounts/${workspaceId}/users/${targetUser.id}`, {
                    method: "PATCH",
                    headers,
                    body: JSON.stringify({ seat_type: "default" })
                });

                if (upgradeRes.ok) {
                    return { success: true, msg: `Seat Drift Complete: -> ${targetEmail}` };
                } else {
                    const errText = await upgradeRes.text();
                    return { success: false, error: `Upgrade failed: ${upgradeRes.status} - ${errText}` };
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
