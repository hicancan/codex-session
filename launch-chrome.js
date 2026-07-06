const puppeteer = require('puppeteer-core');
const os = require('os');
const path = require('path');

async function launchChrome() {
    const userDataDir = path.join(os.homedir(), 'AppData', 'Local', 'Google', 'Chrome', 'User Data');
    
    console.log("Launching Chrome...");
    try {
        const browser = await puppeteer.launch({
            headless: false,
            executablePath: 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
            userDataDir: userDataDir,
            args: ['--remote-debugging-port=9222']
        });
        
        console.log("Chrome successfully launched via script! Port 9222 is open.");
        
        // Wait forever so the browser stays open
        await new Promise(() => {});
    } catch (e) {
        console.error("Failed to launch:", e.message);
    }
}

launchChrome();
