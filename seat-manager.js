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
    try {
        // 连接到当前正在运行的 Chrome (需要 Chrome 启动时带 --remote-debugging-port=9222)
        browser = await puppeteer.connect({
            browserURL: 'http://127.0.0.1:9222',
            defaultViewport: null
        });

        // 寻找一个 chatgpt.com 的标签页作为执行跳板
        const pages = await browser.pages();
        let page = pages.find(p => p.url().includes('chatgpt.com'));
        
        if (!page) {
            page = await browser.newPage();
            await page.goto('https://chatgpt.com/admin/members', { waitUntil: 'domcontentloaded' });
            await new Promise(r => setTimeout(r, 2000)); // 等待 Cloudflare 盾或页面状态就绪
        } else if (!page.url().includes('admin/members')) {
            // 严格强制只在 admin/members 管理员页面发起 API 请求，完美拟态真实管理员操作
            await page.goto('https://chatgpt.com/admin/members', { waitUntil: 'domcontentloaded' });
            await new Promise(r => setTimeout(r, 1000));
        }

        // console.log("Injecting scheduler logic...");
        
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
        console.error("连接 Chrome 失败，请确保 Chrome 已开启调试端口: --remote-debugging-port=9222", err.message);
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
