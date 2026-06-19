'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('@playwright/test');

const REQUIRED_ENV = ['LHU_URL', 'LHU_USERNAME', 'LHU_PASSWORD'];

function validateEnv() {
  const missing = REQUIRED_ENV.filter((key) => !process.env[key]?.trim());
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }

  const url = new URL(process.env.LHU_URL);
  if (url.protocol !== 'https:') {
    throw new Error('LHU_URL must use HTTPS');
  }

  return {
    url: url.toString(),
    username: process.env.LHU_USERNAME,
    password: process.env.LHU_PASSWORD
  };
}

function safeLocation(rawUrl) {
  const url = new URL(rawUrl);
  return `${url.origin}${url.pathname}`;
}

async function visibleCount(locator) {
  let count = 0;
  for (let index = 0; index < await locator.count(); index += 1) {
    if (await locator.nth(index).isVisible()) count += 1;
  }
  return count;
}

async function saveFailureScreenshot(page) {
  const directory = path.resolve('artifacts/lhu-login-check');
  await fs.mkdir(directory, { recursive: true });
  const timestamp = new Date().toISOString().replaceAll(':', '-');
  const file = path.join(directory, `failure-${timestamp}.png`);
  await page.screenshot({ path: file, fullPage: true });
  return path.relative(process.cwd(), file);
}

async function main() {
  const config = validateEnv();
  let browser;
  let page;

  try {
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage();
    page.setDefaultTimeout(15_000);
    page.setDefaultNavigationTimeout(30_000);

    await page.goto(config.url, { waitUntil: 'domcontentloaded' });

    const password = page.locator('input[type="password"]:visible');
    if (await password.count() !== 1) {
      throw new Error(`Expected one visible password field, found ${await password.count()}`);
    }

    const form = password.locator('xpath=ancestor::form[1]');
    if (await form.count() !== 1) {
      throw new Error('Password field is not inside a form');
    }

    const action = await form.getAttribute('action');
    const actionUrl = new URL(action || config.url, page.url());
    if (actionUrl.origin !== new URL(config.url).origin) {
      throw new Error('Refusing to submit credentials to a different origin');
    }

    const preferredUsername = form.locator([
      'input[name="USERID"]:visible',
      'input[name="id"]:visible',
      'input[name="username"]:visible',
      'input[name="user"]:visible',
      'input[autocomplete="username"]:visible'
    ].join(', '));
    const fallbackUsername = form.locator('input[type="text"]:visible, input[type="email"]:visible');
    const username = await preferredUsername.count() === 1 ? preferredUsername : fallbackUsername;

    if (await username.count() !== 1) {
      const fields = await form.locator('input').evaluateAll((inputs) => inputs.map((input) => ({
        type: input.getAttribute('type'),
        name: input.getAttribute('name'),
        id: input.getAttribute('id'),
        autocomplete: input.getAttribute('autocomplete'),
        placeholder: input.getAttribute('placeholder')
      })));
      throw new Error(`Expected one visible username field, found ${await username.count()}; fields=${JSON.stringify(fields)}`);
    }

    const submit = form.locator('button[type="submit"]:visible, input[type="submit"]:visible');
    if (await submit.count() !== 1) {
      throw new Error(`Expected one visible submit control, found ${await submit.count()}`);
    }

    await username.fill(config.username);
    await password.fill(config.password);

    await Promise.all([
      page.waitForLoadState('domcontentloaded').catch(() => undefined),
      submit.click()
    ]);
    await page.waitForTimeout(1_500);

    const passwordFieldsRemaining = await visibleCount(page.locator('input[type="password"]'));
    const logoutSignals = await visibleCount(page.locator([
      'a[href*="logout" i]',
      'a[href*="signout" i]',
      'button:has-text("登出")',
      'a:has-text("登出")',
      'button:has-text("Logout")',
      'a:has-text("Logout")'
    ].join(', ')));
    const leftLoginPage = safeLocation(page.url()) !== safeLocation(config.url);
    const ok = passwordFieldsRemaining === 0 && (leftLoginPage || logoutSignals > 0);

    const composeCandidates = [];
    let composeForm = null;
    let frameLocations = [];
    if (ok) {
      await page.waitForTimeout(3_000);
      for (const currentFrame of page.frames()) {
        const controls = currentFrame.locator('[href], [onclick], [title], [aria-label], [role="button"], input[type="button"], input[type="submit"]');
        for (let index = 0; index < await controls.count(); index += 1) {
          const control = controls.nth(index);
          const descriptor = [
            await control.innerText().catch(() => ''),
            await control.getAttribute('title'),
            await control.getAttribute('aria-label'),
            await control.getAttribute('value'),
            await control.getAttribute('href'),
            await control.getAttribute('onclick'),
            await control.getAttribute('id'),
            await control.getAttribute('class')
          ].filter(Boolean).join(' ').trim();
          if (/寫信|寄信|撰寫|新郵件|compose|write|new.?mail/i.test(descriptor)) {
            composeCandidates.push({
              frame: safeLocation(currentFrame.url()),
              tag: await control.evaluate((element) => element.tagName.toLowerCase()),
              descriptor
            });
          }
        }
      }

      if (process.env.LHU_INSPECT_COMPOSE === 'true') {
        const submenu = page.frames().find((currentFrame) => safeLocation(currentFrame.url()).endsWith('/cgi-bin/submenu'));
        if (!submenu) throw new Error('Could not find the webmail submenu frame');

        const composeControl = submenu.locator('[onclick*="S_GoCompose"]');
        if (await composeControl.count() !== 1) throw new Error('Could not identify one compose control');
        await composeControl.click();
        await page.waitForTimeout(2_000);
        frameLocations = page.frames().map((currentFrame) => safeLocation(currentFrame.url()));

        for (const currentFrame of page.frames()) {
          if (!safeLocation(currentFrame.url()).endsWith('/cgi-bin/genMail')) continue;
          const fields = currentFrame.locator('input, textarea, button, select, [contenteditable="true"]');
          if (await fields.count() === 0) continue;
          const metadata = await fields.evaluateAll((elements) => elements.map((element) => ({
            tag: element.tagName.toLowerCase(),
            type: element.getAttribute('type'),
            name: element.getAttribute('name'),
            id: element.getAttribute('id'),
            title: element.getAttribute('title'),
            placeholder: element.getAttribute('placeholder'),
            action: ['button', 'submit'].includes(element.getAttribute('type'))
              ? element.getAttribute('value')
              : null
          })));
          composeForm = { frame: safeLocation(currentFrame.url()), fields: metadata };
          break;
        }
      }
    }

    console.log(JSON.stringify({
      ok,
      location: safeLocation(page.url()),
      passwordFieldVisible: passwordFieldsRemaining > 0,
      logoutSignalFound: logoutSignals > 0,
      composeCandidates,
      composeForm,
      frameLocations
    }, null, 2));

    if (!ok) {
      throw new Error('Login success could not be verified');
    }
  } catch (error) {
    let screenshot = null;
    if (page) {
      try {
        screenshot = await saveFailureScreenshot(page);
      } catch {
        // Preserve the original login error.
      }
    }

    console.error(JSON.stringify({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      screenshot
    }, null, 2));
    process.exitCode = 1;
  } finally {
    await browser?.close();
  }
}

main();
