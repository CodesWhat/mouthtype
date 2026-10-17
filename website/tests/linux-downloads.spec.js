import { test, expect } from '@playwright/test';

for (const [name, platform, hint, agent, touch] of [
  ['Linux desktop', 'Linux x86_64', 'Linux', 'Mozilla/5.0 (X11; Linux x86_64)', 0],
  ['Linux fallback', 'Linux x86_64', undefined, 'Mozilla/5.0 (X11; Linux x86_64)', 0],
  ['Windows', 'Win32', 'Windows', 'Mozilla/5.0 (Windows NT 10.0)', 0],
  ['Android', 'Linux armv8l', 'Android', 'Mozilla/5.0 (Linux; Android 16)', 5],
  ['iPad desktop mode', 'MacIntel', undefined, 'Mozilla/5.0 (Macintosh; Intel Mac OS X)', 5],
  ['unknown', '', undefined, '', 0],
]) {
  test(`${name} never automatically downloads the Mac ZIP`, async ({ page }) => {
    await page.addInitScript(({ platform, hint, agent, touch }) => {
      Object.defineProperty(navigator, 'platform', { value: platform });
      Object.defineProperty(navigator, 'userAgentData', { value: hint ? { platform: hint } : undefined });
      Object.defineProperty(navigator, 'userAgent', { value: agent });
      Object.defineProperty(navigator, 'maxTouchPoints', { value: touch });
    }, { platform, hint, agent, touch });
    await page.clock.install();
    let requests = 0;
    await page.route('**/download/file', route => { requests++; return route.fulfill({ status: 200, contentType: 'application/zip', body: 'Wrong-platform request fixture' }); });
    await page.goto('/download/');
    await page.clock.runFor(10000);
    await page.evaluate(() => dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true })));
    await page.clock.runFor(10000);
    expect(requests).toBe(0);
    await expect(page.getByRole('link', { name: 'Linux test client', exact: true })).toHaveAttribute('href', '/linux/');
    await expect(page.getByRole('status')).not.toContainText('starts in');
    if (name.startsWith('Linux')) await expect(page.getByRole('status')).toContainText('Linux');
  });
}

for (const width of [1440, 320]) {
  test(`Linux installation is discoverable and honest at ${width}px without JavaScript`, async ({ browser }) => {
    const context = await browser.newContext({ javaScriptEnabled: false, viewport: { width, height: 900 } });
    try {
      const page = await context.newPage();
      await page.goto('/');
      await page.getByRole('link', { name: 'Linux test client', exact: true }).click();
      await expect(page).toHaveURL(/\/linux\/$/);
      await expect(page.getByRole('heading', { level: 1 })).toHaveText('Mouthtype for Linux.');
      const main=page.locator('main');
      for(const text of ['experimental', 'Arch/Omarchy', 'x86_64', 'Hyprland', 'PipeWire', 'source', 'install.py', 'setup_speech.py', 'recovery-only', 'no Linux GUI', 'Physical microphone']) await expect(main).toContainText(text);
      await expect(page.getByRole('link', { name: 'Download Linux source', exact: false })).toHaveAttribute('href', '/source');
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.goto('/start/');
      await expect(page.getByRole('link', { name: 'Linux test client', exact: true })).toHaveAttribute('href', '/linux/');
      await page.goto('/download/');
      await page.getByRole('link', { name: 'Linux test client', exact: true }).click();
      await expect(page).toHaveURL(/\/linux\/$/);
    } finally { await context.close(); }
  });
}

test('Linux visitors can explicitly choose the Mac download', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator,'platform',{value:'Linux x86_64'});
    Object.defineProperty(navigator,'userAgentData',{value:undefined});
  });
  await page.clock.install();
  const requests=[];
  await page.route('**/download/file',route=>{requests.push(route.request().url());return route.fulfill({status:200,headers:{'content-type':'application/zip','content-disposition':'attachment; filename="Mouthtype.zip"'},body:'Explicit Mac fixture'});});
  await page.goto('/download/');
  const received=page.waitForEvent('download');
  await page.getByRole('link',{name:'Download now',exact:false}).click();
  await received;
  await page.clock.runFor(10000);
  expect(requests).toHaveLength(1);
});

test('Mac client hints keep one countdown when the page returns from cache', async ({ page }) => {
  await page.addInitScript(() => {
    Object.defineProperty(navigator,'platform',{value:'MacIntel'});
    Object.defineProperty(navigator,'userAgentData',{value:{platform:'macOS'}});
    Object.defineProperty(navigator,'maxTouchPoints',{value:0});
  });
  await page.clock.install();
  const requests=[];
  await page.route('**/download/file',route=>{requests.push(route.request().url());return route.fulfill({status:200,headers:{'content-type':'application/zip','content-disposition':'attachment; filename="Mouthtype.zip"'},body:'Mac timing fixture'});});
  await page.goto('/download/');
  await page.clock.runFor(3000);
  await page.evaluate(() => {
    dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));
    dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));
    dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));
  });
  await page.clock.runFor(4999);
  expect(requests).toHaveLength(0);
  const received=page.waitForEvent('download');
  await page.clock.runFor(1);
  await received;
  await page.clock.runFor(10000);
  expect(requests).toHaveLength(1);
});
